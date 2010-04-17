#!/usr/bin/env ruby
# echoproof
# see README for more information

require 'rubygems'
require 'twitter/json_stream'
require 'json'
require 'twitter'

# Load configuration
cwd = File.dirname(File.expand_path(__FILE__))
config = YAML.load(File.open(cwd+'/config.yml'))
USERNAME = config['username']
PASSWORD = config['password']
raise "Both username and password are required; check your config.yml" if USERNAME.blank? || PASSWORD.blank?

# What gets sent to your new followers
def welcome_message
  "Welcome! Use coupon code ADTECH on http://140proof.com for $50 of free ads. Follow @140ProofAds for breaking news in Twitter advertising"
end

# Invoked after a user follows us
def follow_callback(message)

  follower = Twitter.user(message["source"]["id"])
  
  # Follow them back & DM them
  auth = Twitter::HTTPAuth.new(USERNAME, PASSWORD)
  client = Twitter::Base.new(auth)
  puts "Following @#{follower.screen_name} ..."
  client.friendship_create(follower.id) rescue (STDERR.puts "Error following  @#{follower.screen_name}: #{$!}")
  puts "DMing welcome message: #{welcome_message}"
  client.direct_message_create(follower.id, welcome_message) rescue (STDERR.puts "Error DMing @#{follower.screen_name}: #{$!}")

  return true
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
