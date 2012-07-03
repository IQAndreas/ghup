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

def get(url, token)
  uri = URI.parse(url)

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  req = Net::HTTP::Get.new(uri.path)
  req['Authorization'] = "token #{token}" if token

  return http.request(req)
end

# Do a post to the given url, with the payload and optional basic auth.
def post(url, token, params, headers)
  uri = URI.parse(url)

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  req = Net::HTTP::Post.new(uri.path, headers)
  req['Authorization'] = "token #{token}" if token

  return http.request(req, params)
end

def delete(url, token)
  uri = URI.parse(url)

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  req = Net::HTTP::Delete.new(uri.path)
  req['Authorization'] = "token #{token}" if token

  return http.request(req)
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


# Configuration and setup
# -----------------------

# Get Oauth token for this script.
token = `git config --get github.upload-script-token`.chomp
force_upload = false

# The file we want to upload, and repo where to upload it to.
file = Pathname.new(ARGV[0])
repo = ARGV[1] || `git config --get remote.origin.url`.match(/git@github.com:(.+?)\.git/)[1]

file_name = file.basename.to_s
file_description = ""

# Parse command line options using OptionParser
# -----------------------

OptionParser.new do |opts|

	opts.banner = "Usage: github-upload.rb <file-name> [<repository>] [options]"
	
	opts.on("-d", "--description [DESCRIPTION]",
			"Add a description to the uploaded file.") do |arg_description|
		file_description = arg_description
	end
	
	opts.on("-n", "--name [NAME]",
			"New name of the uploaded file.") do |arg_name|
		file_name = arg_name
	end
	
	opts.on("-f", "--force",
			"If a file with that name already exists on the server, replace it with this one.") do
		force_upload = true
	end
	
end.parse!



# The actual, hard work
# ---------------------


if force_upload

	# Make sure the file doesn't already exist
	res = get("https://api.github.com/repos/#{repo}/downloads", token)
	info = JSON.parse(res.body)
	info.each do |remote_file|
		remote_file_name = remote_file["name"].to_s
		if remote_file_name == file_name then
			# Delete already existing files
			puts "Deleting existing file '#{remote_file_name}'"
			remote_file_id = remote_file["id"].to_s
			res = delete("https://api.github.com/repos/#{repo}/downloads/#{remote_file_id}", token)
		end
	end

end


# Register the download at github.
res = post("https://api.github.com/repos/#{repo}/downloads", token, {
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
