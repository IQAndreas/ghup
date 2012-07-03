#!/usr/bin/env ruby

# Die if something goes wrong.
def die(msg); puts(msg); exit!(1); end

# First thing we do is check the ruby version. This script requires 1.9, die
# if that's not the case.
die("This script requires ruby 1.9") unless RUBY_VERSION =~ /^1.9/


require 'json'
require 'net/https'
require 'pathname'
require 'optparse'



# Extensions
# ----------

# We extend Pathname a bit to get the content type.
class Pathname
  def type
    flags = RUBY_PLATFORM =~ /darwin/ ? 'Ib' : 'ib'
    `file -#{flags} #{realpath}`.chomp.gsub(/;.*/,'')
  end
end



# Helpers
# -------

def get_input(message, error_message)
  puts message
  result = STDIN.gets.chomp
  die error_message if result == ""
  return result
end

def get_http_request(uri, token, request, params = "")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE if $options[:skip_ssl_verification]
  request['Authorization'] = "token #{token}" if token  
  return http.request(request, params)
end

def get(url, token)
  uri = URI.parse(url)
  req = Net::HTTP::Get.new(uri.path)
  return get_http_request(uri, token, req)
end

# Do a post to the given url, with the payload and optional basic auth.
def post(url, token, params, headers)
  uri = URI.parse(url)
  req = Net::HTTP::Post.new(uri.path, headers)
  return get_http_request(uri, token, req, params)
end

def post_basic_auth(url, username, password, params, headers)
  uri = URI.parse(url)
  req = Net::HTTP::Post.new(uri.path, headers)
  req.basic_auth username, password
  return get_http_request(uri, nil, req, params)
end

def request_api_token(username, password)
  res = post_basic_auth("https://api.github.com/authorizations", username, password, 
    { 'note' => "file upload script", 'scopes' => ["repo"] }.to_json, {})
  die "Invalid username or password." if res.class == Net::HTTPUnauthorized
  
  info = JSON.parse(res.body)
  return info["token"]
end

def delete(url, token)
  uri = URI.parse(url)
  req = Net::HTTP::Delete.new(uri.path)
  return get_http_request(uri, token, req)
end

def urlencode(str)
  str.gsub(/[^a-zA-Z0-9_\.\-]/n) {|s| sprintf('%%%02x', s[0].to_i) }
end

# Yep, ruby net/http doesn't support multipart. Write our own multipart generator.
# The order of the params is important, the file needs to go as last!
def build_multipart_content(params)
  parts, boundary = [], "#{rand(1000000)}-we-are-all-doomed-#{rand(1000000)}"

  params.each do |name, value|
    data = []
    if value.is_a?(Pathname) then
      data << "Content-Disposition: form-data; name=\"#{urlencode(name.to_s)}\"; filename=\"#{value.basename}\""
      data << "Content-Type: #{value.type}"
      data << "Content-Length: #{value.size}"
      data << "Content-Transfer-Encoding: binary"
      data << ""
      data << value.read
    else
      data << "Content-Disposition: form-data; name=\"#{urlencode(name.to_s)}\""
      data << ""
      data << value
    end

    parts << data.join("\r\n") + "\r\n"
  end

  [ "--#{boundary}\r\n" + parts.join("--#{boundary}\r\n") + "--#{boundary}--", {
    "Content-Type" => "multipart/form-data; boundary=#{boundary}"
  }]
end


# Parse command line options using OptionParser
# -----------------------

$options = {}

OptionParser.new do |opts|

  opts.banner = "Usage: github-upload.rb <file-name> [<repository>] [options]"
  
  opts.on("-d", "--description [DESCRIPTION]",
      "Add a description to the uploaded file.") do |arg_description|
    $options[:file_description] = arg_description
  end
  
  opts.on("-n", "--name [NAME]",
      "New name of the uploaded file.") do |arg_name|
    $options[:file_name] = arg_name
  end
  
  opts.on("-f", "--force",
      "If a file with that name already exists on the server, replace it with this one.") do
    $options[:force_upload] = true
  end
  
  opts.on("-t", "--token [TOKEN]",
      "Manually specify a GitHub API token. Useful if you want to temporarily upload a file under a different GitHub account.") do |arg_token|
    $options[:token] = arg_token
  end
  
  opts.on("-u", "--username [USERNAME]",
      "Manually specify a GitHub username to use. If used without '--reset-token', it will not store an API key or any other information.") do |arg_username|
    $options[:username] = arg_username
  end
  
  opts.on("-p", "--password [PASSWORD]",
      "Manually specify a GitHub password to use. See '--username' for usage.") do |arg_password|
    $options[:password] = arg_password
  end
  
  opts.on("-t", "--token [TOKEN]",
      "Manually specify a GitHub API token. Useful if you want to temporarily upload a file under a different GitHub account.") do |arg_token|
    $options[:token] = arg_token
  end
  
  opts.on("--reset-token",
      "Reset the GitHub API token, forcing you to re-enter your GitHub user information.") do
    $options[:reset_token] = true
  end
  
  opts.on("--skip-ssl-verification",
      "Skip SSL Verification in the HTTP Request.") do
    $options[:skip_ssl_verification] = true
  end
  
  opts.on("-h", "--help", 
      "Show this message") do
    puts opts
    exit
  end
  
end.parse!



# Configuration and setup
# -----------------------

# The file we want to upload, and repo where to upload it to.
die("Please specify a file to upload.") if ARGV.length < 1
file = Pathname.new(ARGV[0])
repo = ARGV[1] || `git config --get remote.origin.url`.match(/git@github.com:(.+?)\.git/)[1]

file_name =        $options[:file_name] || file.basename.to_s
file_description = $options[:file_description] || ""


# The actual, hard work
# ---------------------

# Get Oauth token for this script.
$options[:token] = `git config --get github.upload-script-token`.chomp unless $options[:token]

if (!$options[:reset_token]) && ($options[:username] || $options[:password]) then

  die "Please specify both a username and password, or use the --reset-token flag." if !($options[:username] && $options[:password])

  # Generate a temporary token, but don't store it to their git config
  $options[:token] = request_api_token($options[:username], $options[:password])

elsif $options[:reset_token] || !$options[:token] then

  if (!$options[:username] || !$options[:password]) then
    # Don't display the message if they have aleady given both parameters
    puts "To upload a file to GitHub, you need to generate a token. This only needs to be done once, and requires your GitHub username and password. The private data will not be stored after it is used."
  end
  
  username = $options[:username] || get_input("Please enter your GitHub username:", "Invalid username. Cancelling.")
  password = $options[:password] || get_input("Please enter your GitHub password:", "Invalid password. Cancelling.")
  
  # Store the token so users don't have to keep re-entering their login information
  token = request_api_token(username, password)
  `git config --global github.upload-script-token #{token}`
  $options[:token] = token
  
  puts "Sucessfully generated new token."

end
#curl -X POST -u #{gh_user}:#{gh_password}

if $options[:force_upload] then

  # Make sure the file doesn't already exist
  res = get("https://api.github.com/repos/#{repo}/downloads", $options[:token])
  info = JSON.parse(res.body)
  info.each do |remote_file|
    remote_file_name = remote_file["name"].to_s
    if remote_file_name == file_name then
      # Delete already existing files
      puts "Deleting existing file '#{remote_file_name}'"
      remote_file_id = remote_file["id"].to_s
      res = delete("https://api.github.com/repos/#{repo}/downloads/#{remote_file_id}", $options[:token])
    end
  end

end


# Register the download at github.
res = post("https://api.github.com/repos/#{repo}/downloads", $options[:token], {
  'name' => file_name, 'size' => file.size.to_s,
  'description' => file_description,
  'content_type' => file.type.gsub(/;.*/, '')
}.to_json, {})

die("File already exists named '#{file_name}'.") if res.class == Net::HTTPClientError
die("GitHub doesn't want us to upload the file.") unless res.class == Net::HTTPCreated


# Parse the body and use the info to upload the file to S3.
info = JSON.parse(res.body)
res = post(info['s3_url'], nil, *build_multipart_content({
  'key' => info['path'], 'acl' => info['acl'], 'success_action_status' => 201,
  'Filename' => info['name'], 'AWSAccessKeyId' => info['accesskeyid'],
  'Policy' => info['policy'], 'signature' => info['signature'],
  'Content-Type' => info['mime_type'], 'file' => file
}))

die("S3 is mean to us.") unless res.class == Net::HTTPCreated


# Print the URL to the file to stdout.
puts "#{info['s3_url']}#{info['path']}"
