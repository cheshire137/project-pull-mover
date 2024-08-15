#!/usr/bin/env ruby

require "octokit"
require "optparse"

options = {}
option_parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{__FILE__} [options]"
  opts.on("-p NUM", "--project-number", Integer,
    "Project number (required), e.g., 123 for https://github.com/orgs/someorg/projects/123")
  opts.on("-o OWNER", "--project-owner", String,
    "Project owner login (required), e.g., someorg for https://github.com/orgs/someorg/projects/123")
  opts.on("-s STATUS", "--status-field", String,
    "Status field name, name of a single-select field in the project")
  opts.on("-i ID", "--in-progress", String, "Option ID of 'In progress' column")
  opts.on("-a ID", "--not-against-main", String, "Option ID of 'Not against main' column")
  opts.on("-n ID", "--needs-review", String, "Option ID of 'Needs review' column")
  opts.on("-r ID", "--ready-to-deploy", String, "Option ID of 'Ready to deploy' column")
  opts.on("-c ID", "--conflicting", String, "Option ID of 'Conflicting' column")
  opts.on("-g IDS", "--ignored", Array,
    "Comma-separated list of option IDs of columns like 'Blocked' or 'On hold'")
end
option_parser.parse!(into: options)

options[:"status-field"] ||= "Status"
pp options
project_number = options[:"project-number"]
project_owner = options[:"project-owner"]

unless project_number && project_owner
  puts option_parser
  exit 1
end

puts "Working with project #{project_number} owned by @#{project_owner}"
token = `gh auth token`
client = Octokit::Client.new(access_token: token)
username = client.user[:login]
puts "Authenticated as GitHub user @#{username}"
