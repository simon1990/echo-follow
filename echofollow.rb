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
require 'chronic'

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

def db_file
  "#{cwd}/database.sqlite3"
end

# Text that gets sent to your new followers!
def welcome_message
  "Hi, thanks for following! Check out http://mywebsite.com for more info"
end

def init_database(db)
  unless db.table_exists?(:subscribers)
    puts "Creating table: subscribers"
    db.create_table :subscribers do
      primary_key :id
      String :screen_name
      DateTime :created_at
    end
  end

  unless db.table_exists?(:messages)
    puts "Creating table: messages"
    db.create_table :messages do
      primary_key :id
      String :text
      DateTime :created_at
      DateTime :scheduled_at
      DateTime :sent_at
    end
  end
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
  if `uname` =~ /Darwin/ # Mac
    %x(open #{oauth.request_token.authorize_url})
  else
    puts "Visit this url: #{oauth.request_token.authorize_url}"
  end
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
  if DB[:subscribers].where(:screen_name => follower.screen_name).count > 0
    puts "Error: we've already messaged this user #{follower.screen_name.inspect}, skipping"
    return false
  end

  puts "Following @#{follower.screen_name} ..."
  client.friendship_create(follower.id) rescue (STDERR.puts "Error following  @#{follower.screen_name}: #{$!}")
  puts "DMing welcome message: #{welcome_message} ..."
  client.direct_message_create(follower.id, welcome_message) rescue (STDERR.puts "Error DMing @#{follower.screen_name}: #{$!}")

  add_subscriber(follower.screen_name)

  return true
end

# Record our new followers/subscriber to our database
def add_subscriber(username)
  if subscribers.where(:screen_name => username).count > 0
    puts "- #{username.inspect} is already subscribed! Skipping."
  else
    puts "+ Adding subscriber #{username.inspect}..."
    subscribers.insert(:screen_name => username, :created_at => Time.now)
  end
end

# Send msg to all of our subscribers
def broadcast(message)
  puts "Broadcasting message: #{message.inspect}"
  subscribers.each do |user|
    puts "* #{user[:screen_name]} ..."
    follower = client.user(user[:screen_name])
    client.direct_message_create(follower.id, message) rescue (STDERR.puts "Error DMing @#{follower.screen_name}: #{$!}")
  end
end

def subscribers
  DB[:subscribers]
end

# Message scheduling
def schedule_message(message, time)
  puts "Scheduling message for #{time.inspect}: #{message.inspect}" 

  raise "Can't schedule a blank message!" if message.empty?
  raise "No messages table!" if DB.nil? || DB[:messages].nil?
  raise "Can't schedule a message for before this script was launched! time=#{time.inspect}, running_since=#{running_since.inspect}" if time < running_since
  messages.insert(:text => message, :scheduled_at => time.utc, :created_at => Time.now)
rescue
  STDERR.puts "ERROR: #{$!}"
end

def messages
  DB[:messages]
end

def future_messages
  messages.where('scheduled_at > ?', Time.now.utc).order(:scheduled_at)
end

def pending_messages
  messages.where('sent_at IS NULL AND scheduled_at < ?', Time.now.utc).order(:scheduled_at)
end

def sent_messages
  messages.where('sent_at IS NOT NULL').order(:scheduled_at)
end


# The main loop
def run

  # Authenticate
  begin
    connect_to_twitter
  rescue OAuth::Unauthorized
    puts "> OAUTH FAIL! #{$!}"
    exit 1
  end

  # Event processing loop for Twitter UserStream
  EventMachine::run do
    @processed_items = 0
    puts "\nOpening userstream connection... "
    stream = Twitter::JSONStream.connect(
      :user_agent => "Echofollow 1.0 <http://github.com/bubblefusionlabs/echofollow>",
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
        # We only care about the 1st message, our followings list
        if json.keys == ["friends"]
          puts "Received initial friends list, connection OK!"
        else
          puts "Unhandled message or event -- ignoring"
          # puts json.inspect
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

    # Timer loop for broadcasting scheduled messages
    @n ||= 0
    timer = EventMachine::add_periodic_timer(5) do
      @n += 1
      puts "n=#{@n}, #{messages.count} messages, #{pending_messages.count} pending, #{future_messages.count} scheduled -- the time is #{Time.now} (#{Time.now.utc})"
      if pending_messages.count > 0
        message = pending_messages.first
        broadcast(message[:text])
        # messages.where(:id => message[:id]).delete
	messages.where(:id => message[:id]).update(:sent_at => Time.now.utc)
        #message[:sent_at] = Time.now.utc
      end
      # timer.cancel if (@n+=1) > 2
    end

    # Catch UNIX kill sigs so we can close connections
    trap('TERM') do
      stream.stop
      EventMachine.stop if EventMachine.reactor_running?
    end
  end
end

def running_since
  @running_since
end


# Go
DB = Sequel.sqlite(db_file)
DB.drop_table(:messages) if DB.table_exists?(:messages) # RESET
init_database(DB)
@running_since ||= Time.now

# Note: Chronic uses local system time and knows nothing of timezones (w/o Rails)
# So for a server set to UTC, *all times must be entered in UTC* (+0:00)
puts "Current subscribers: #{DB[:subscribers].map {|f| f[:screen_name] }.inspect}"
puts
schedule_message("Sup my dawg! This message was scheduled for 2 minutes after launch", Chronic.parse("2 minutes from now") )
schedule_message("Message2...", Chronic.parse("1:20am") )
schedule_message("Message from the past which should be ignored", Chronic.parse("10 minutes ago"))

run
exit 0
