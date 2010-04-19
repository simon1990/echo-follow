#!/usr/bin/env ruby
# echoproof
# see README for more information

require 'rubygems'
require 'twitter/json_stream'
require 'json'
require 'twitter'
require 'sequel'

# Load configuration
cwd = File.dirname(File.expand_path(__FILE__))
config = YAML.load(File.open(cwd+'/config.yml'))
USERNAME = config['username']
PASSWORD = config['password']
raise "Both username and password are required; check your config.yml" if USERNAME.blank? || PASSWORD.blank?

# What gets sent to your new followers
def welcome_message
  "Use coupon code ADTECH when checking out at http://140proof.com for $50 of free ads. Follow @140ProofAds for more Twitter advertising news."
end

# Invoked after a user follows us
def follow_callback(message)

  # Check if we've already autoresponded to them
  follower = Twitter.user(message["source"]["id"])
  if DB[:followers].where(:screen_name => follower.screen_name).first.nil?
    puts "Error: we've already messaged this user #{follower.screen_name.inspect}, skipping"
    return false
  end

  # Follow them back & DM them
  auth = Twitter::HTTPAuth.new(USERNAME, PASSWORD)
  client = Twitter::Base.new(auth)
  puts "Following @#{follower.screen_name} ..."
  client.friendship_create(follower.id) rescue (STDERR.puts "Error following  @#{follower.screen_name}: #{$!}")
  puts "DMing welcome message: #{welcome_message} ..."
  client.direct_message_create(follower.id, welcome_message) rescue (STDERR.puts "Error DMing @#{follower.screen_name}: #{$!}")

  log_as_responded(follower.screen_name)

  return true
end

# Stash a user we've DM'd into our database
def log_as_responded(username)
  puts "Logging user as added, #{username.inspect} ..."
  followers = DB[:followers]
  followers.insert(:screen_name => username, :created_at => Time.now)
end

# ------

# Initialize our storage
DB = Sequel.sqlite("#{cwd}/database.sqlite3")
unless DB.table_exists?(:followers)
  DB.create_table :followers do
    primary_key :id
    String :screen_name
    DateTime :created_at
  end
end

# Processing loop
EventMachine::run do
  stream = Twitter::JSONStream.connect(
    :host    => 'betastream.twitter.com',
    :path    => '/2b/user.json',
    :auth    => "#{USERNAME}:#{PASSWORD}"
  )

  stream.each_item do |item|
    json = JSON.parse(item)
    puts "\n-------------------"
    puts json.inspect

    event = json["event"]
    case event.to_s
    when "follow"
      follow_callback(json)
    else
      puts "Unhandled event: #{event.inspect} -- ignoring"
    end
  end

  stream.on_error do |message|
    STDERR.puts "Error: #{message}"
    if message =~ /401 Unauthorized/
      STDERR.puts "Are your username/password correct? Aborting."
      exit!
    end
    # No need to worry here. It might be an issue with Twitter.
    # Log message for future reference. JSONStream will try to reconnect after a timeout.
  end

  stream.on_max_reconnects do |timeout, retries|
    # Something is wrong on our side. Send us an email.
    STDERR.puts "Stream max reconnects reached! retries=#{retries}"
  end
end

exit 0
