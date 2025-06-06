require 'google/apis/gmail_v1'
require 'googleauth'
require 'googleauth/stores/file_token_store'
require 'fileutils'
require 'base64'
require 'openai'
require 'dotenv'

Dotenv.load

SCOPES = ['https://mail.google.com/'].freeze

def get_gmail_service
  client_id = Google::Auth::ClientId.from_file('credentials.json')
  token_store = Google::Auth::Stores::FileTokenStore.new(file: 'token.yaml')
  authorizer = Google::Auth::UserAuthorizer.new(client_id, SCOPES, token_store)
  user_id = 'default'
  credentials = authorizer.get_credentials(user_id)

  if credentials.nil?
    url = authorizer.get_authorization_url(base_url: 'urn:ietf:wg:oauth:2.0:oob')
    puts "Open the following URL in your browser and enter the resulting code:"
    puts url
    code = gets.chomp
    credentials = authorizer.get_and_store_credentials_from_code(
      user_id: user_id, code: code, base_url: 'urn:ietf:wg:oauth:2.0:oob'
    )
  end

  gmail = Google::Apis::GmailV1::GmailService.new
  gmail.authorization = credentials
  gmail
end

def get_openai_client
  OpenAI::Client.new(
    access_token: ENV.fetch("OPENAI_API_KEY"),
    log_errors: true
  )
end

def get_user_name
  [ENV.fetch("USER_FIRST_NAME"), ENV.fetch("USER_LAST_NAME")]
end

def fetch_emails(gmail, page_token)
  begin
    results = gmail.list_user_messages('me', label_ids: ['INBOX'], page_token: page_token)
    messages = results.messages || []
    [messages, results.next_page_token]
  rescue => e
    puts "🔵 Failed to fetch emails: #{e}"
    [[], nil]
  end
end

require 'base64'

def clean_email_body(body)
  return '' if body.nil? || body.empty?

  body
    .gsub(/[\r\n]+\s*[\r\n]+/, "\n\n")  # Remove multiple blank lines and whitespace
    .gsub(/https?:\/\/[^\s]+\s+/, '')    # Remove HTML-style links
    .gsub(/&[a-zA-Z0-9#]+;/, '')         # Remove HTML entities
    .gsub(/^\s*[\r\n]/m, '')             # Remove empty lines that just contain whitespace
    .gsub(/\s+/, ' ')                    # Remove multiple spaces
    .strip                               # Clean up any remaining whitespace at start/end
end

def parse_email_data(gmail, message_info)
  begin
    msg = gmail.get_user_message('me', message_info.id, format: 'full')
    headers = msg.payload.headers
    subject = headers.find { |h| h.name == 'Subject' }&.value
    to = headers.find { |h| h.name == 'To' }&.value
    sender = headers.find { |h| h.name == 'From' }&.value
    cc = headers.find { |h| h.name == 'Cc' }&.value

    puts "Fetched email - Subject: #{subject}, Sender: #{sender}"

    parts = msg.payload.parts || []
    body_data = ''

    if parts.empty? && msg.payload.body.data
      body_data = safe_decode64(msg.payload.body.data)
    else
      parts.each do |part|
        if part.mime_type == 'text/plain'
          body_data = safe_decode64(part.body.data) if part.body.data
          break
        end
      end
    end

    # Ensure body_data is UTF-8 encoded and cleaned
    body_data = body_data.force_encoding('UTF-8')
      .encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
    body_data = clean_email_body(body_data)

    {
      subject: subject,
      to: to,
      from: sender,
      cc: cc,
      labels: msg.label_ids,
      body: body_data
    }
  rescue => e
    puts "🔵 Failed to parse email data: #{e}"
    {}
  end
end

def safe_decode64(data)
  Base64.urlsafe_decode64(data)
rescue ArgumentError
  # If urlsafe_decode64 fails, try regular decode64
  begin
    Base64.decode64(data)
  rescue ArgumentError
    # If both fail, return the original string
    data
  end
end

def evaluate_email(email_data, user_first_name, user_last_name, client)
  max_email_len = 3000
  user_first_name = user_first_name.strip
  user_last_name = user_last_name.strip

  system_message_content = <<~PROMPT
    You help manage the Gmail inbox for #{user_first_name} #{user_last_name}. Classify each email as worth reading or not. Respond with "True" if the email is promotional or spam and should be ignored, otherwise respond with "False".

    Criteria for ignoring an email:
    - Promotional content such as offers or discounts.
    - Automated notifications not written by an actual person.
    - Mailing list or mass-sent messages that don't personally address #{user_first_name}.
    - Obvious spam with suspicious links or scam-like details.

    Do not ignore messages from real people (especially family members with the same last name, close acquaintances, or potential contacts) and keep emails that require action for important matters.

    If uncertain, respond with "False".

    The user prompt will include:
    Subject: <email subject>
    To: <to names, to emails>
    From: <from name, from email>
    Cc: <cc names, cc emails>
    Gmail labels: <labels>
    Body: <plaintext body of the email>

    Only answer with "True" or "False".
  PROMPT

  system_message = {
    role: "system",
    content: system_message_content.strip
  }
  truncated_body = email_data[:body] ? (email_data[:body][0...max_email_len] + (email_data[:body].length > max_email_len ? "..." : "")) : ""

  user_message = {
    role: "user",
    content: "Subject: #{email_data[:subject]}\n" \
             "To: #{email_data[:to]}\n" \
             "From: #{email_data[:from]}\n" \
             "Cc: #{email_data[:cc]}\n" \
             "Gmail labels: #{email_data[:labels]}\n" \
             "Body: #{truncated_body}"
  }

  begin
    response = client.chat(
      parameters: {
        model: "gpt-4o-mini",
        messages: [system_message, user_message],
        max_tokens: 1,
        temperature: 0.0
      }
    )
    response.dig("choices", 0, "message", "content").strip == "True"
  rescue => e
    puts "🔵 Failed to evaluate email with GPT-4: #{e}"
    false
  end
end

def process_email(gmail, message_info, email_data_parsed, user_first_name, user_last_name, client)
  begin
    should_delete_email = evaluate_email(email_data_parsed, user_first_name, user_last_name, client)
  rescue => e
    puts "🔵 Failed to evaluate email: #{e}"
    return 0
  end

  if should_delete_email
    puts "🔴 Email is not worth the time, deleting email"
    begin
      gmail.delete_user_message('me', message_info.id)
      puts "🗑️ Email deleted successfully"
      return 1
    rescue => e
      puts "🔵 Failed to delete email: #{e}"
    end
  else
    puts "🟢 Email is worth the time, keeping it"
  end
  0
end

def report_statistics(total_unread_emails, total_pages_fetched, total_marked_as_read)
  puts "Total number of emails fetched: #{total_unread_emails}"
  puts "Total number of pages fetched: #{total_pages_fetched}"
  puts "Total number of emails deleted: #{total_marked_as_read}"
  puts "Final number of emails: #{total_unread_emails - total_marked_as_read}"
end

def main
  gmail = get_gmail_service
  client = get_openai_client
  user_first_name, user_last_name = get_user_name

  page_token = nil

  total_unread_emails = 0
  total_pages_fetched = 0
  total_marked_as_read = 0

  loop do
    messages, page_token = fetch_emails(gmail, page_token)
    total_pages_fetched += 1
    puts "Fetched page #{total_pages_fetched} of emails"

    total_unread_emails += messages.length
    messages.each do |message_info|
      email_data_parsed = parse_email_data(gmail, message_info)
      # puts email_data_parsed
      total_marked_as_read += process_email(gmail, message_info, email_data_parsed, user_first_name, user_last_name, client)
    end

    break unless page_token
  end

  report_statistics(total_unread_emails, total_pages_fetched, total_marked_as_read)
end

main if __FILE__ == $PROGRAM_NAME
