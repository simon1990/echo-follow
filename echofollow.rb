#!/usr/bin/env ruby

# -- ECHOFOLLOW --
# Twitter autoresponder & DM notifier
# See README for more information

require 'config_store'
require 'rubygems'
require 'bundler/setup'
require 'twitter'
require 'json'
require 'twitter/json_stream'
require 'eventmachine'
require 'sequel'

# Load configuration
def config
  if @config.nil?
    @config = ConfigStore.new(cwd+'/config.yml')
    raise "OAuth token & secret are required; check your config.yml" if @config['token'].blank? || @config['secret'].blank?
  end
  return @config
end

def cwd
  File.dirname(File.expand_path(__FILE__))
end

# Text that gets sent to your new followers!
def welcome_message
  "Hi, thanks for following! Check out http://mywebsite.com for more info"
end

# Establish connection to Twitter
def connect_to_twitter
  oauth = Twitter::OAuth.new(config['token'], config['secret'])
  config['rtoken']  = oauth.request_token.token
  config['rsecret'] = oauth.request_token.secret

  if config['atoken'] && config['asecret']
    oauth.authorize_from_access(config['atoken'], config['asecret'])
  elsif config['rtoken'] && config['rsecret']
  puts "> redirecting you to twitter to authorize..."
  %x(open #{oauth.request_token.authorize_url})
  print "> what was the PIN twitter provided you with? "
  pin = gets.chomp

  oauth.authorize_from_request(config['rtoken'], config['rsecret'], pin)
  config.update({
   'atoken'  => oauth.access_token.token,
   'asecret' => oauth.access_token.secret,
  }).delete('rtoken', 'rsecret')
  end

  @client = Twitter::Base.new(oauth)
end

def client
  @client
end

# Invoked after a user follows us
def follow_callback(message)

  # Check if we've already autoresponded to them
  follower = client.user(message["source"]["id"])
  if DB[:followers].where(:screen_name => follower.screen_name).count > 0
    puts "Error: we've already messaged this user #{follower.screen_name.inspect}, skipping"
    return false
  end

  puts "Following @#{follower.screen_name} ..."
  client.friendship_create(follower.id) rescue (STDERR.puts "Error following  @#{follower.screen_name}: #{$!}")
  puts "DMing welcome message: #{welcome_message} ..."
  client.direct_message_create(follower.id, welcome_message) rescue (STDERR.puts "Error DMing @#{follower.screen_name}: #{$!}")

  log_as_responded(follower.screen_name)

  return true
end

# Record that we've DM'd a user in our database
def log_as_responded(username)
  puts "Logging user as added, #{username.inspect} ..."
  followers = DB[:followers]
  followers.insert(:screen_name => username, :created_at => Time.now)
end

# The main loop
def run
  puts "Running as @#{config['username']}"

  # Initialize our storage
  unless DB.table_exists?(:followers)
    DB.create_table :followers do
      primary_key :id
      String :screen_name
      DateTime :created_at
    end
  end

  # Authenticate
  begin
    connect_to_twitter
  rescue OAuth::Unauthorized
    puts "> OAUTH FAIL! #{$!}"
    exit 1
  end

  # Processing loop
  EventMachine::run do
    @processed_items = 0
    puts "Opening userstream connection... "
    stream = Twitter::JSONStream.connect(
      :user_agent => "Echofollow 1.0 <http://140proof.com>",
      :host => 'userstream.twitter.com',
      :path => '/2/user.json',
      :ssl => true, # Required for Oauth!
      # :auth => "#{USERNAME}:#{PASSWORD}"
      :oauth => {
        :consumer_key    => config['token'],
        :consumer_secret => config['secret'],
        :access_key      => config['atoken'],
        :access_secret   => config['asecret']
      }
    )
    puts "Waiting for 1st message (friends list) ..."

    stream.each_item do |item|
      @processed_items += 1
      json = JSON.parse(item)
      puts "\n------- ##{@processed_items} --------"

      event = json["event"]
      case event.to_s
      when "follow"
        follow_callback(json)
      else
        puts json.inspect

        # Initial friends list -- 1st message
        if json.keys == ["friends"]
          puts "Received initial friends list, connection OK!"
        else
          puts "Unhandled event: #{event.inspect} -- ignoring"
        end
      end
    end

    stream.on_error do |message|
      STDERR.puts "Twitter Error: #{message}"
      if message =~ /401 Unauthorized/
        STDERR.puts "FATAL: 401 Unauthorized, are your credentials correct? Aborting."
        exit 1
      end
      # No need to worry here. It might be an issue with Twitter.
      # Log message for future reference. JSONStream will try to reconnect after a timeout.
    end

    stream.on_reconnect do |timeout, retries|
      $stdout.print "reconnecting in: #{timeout} seconds\n"
      $stdout.flush
    end

    stream.on_max_reconnects do |timeout, retries|
      # Something is wrong on our side. Send us an email.
      STDERR.puts "FATAL: max stream reconnects reached! retries=#{retries}"
      exit 1
    end

    trap('TERM') do
      stream.stop
      EventMachine.stop if EventMachine.reactor_running?
    end
  end
end

DB = Sequel.sqlite("#{cwd}/database.sqlite3")
run
exit 0
