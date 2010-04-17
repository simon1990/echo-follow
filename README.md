EchoProof
---------

A service that uses the new Twitter User Streams API to monitor
your account and send a welcome DM to new followers (and potentially other actions)


Dependencies
------------

You'll need the following rubygems:

* twitter
* twitter-stream
* json
* daemons

Optional:

* tinder -- enable Campfire notifications

Usage
-----

* cp config.sample.yml config.yml
* edit to your liking
$ ruby echoproof.rb

To run as a daemon:
$ ruby daemon start

By default the daemon dumps its pid & logfile to the current working directory


Contributors
-----------
Jamie Wilkinson <jamie@140proof.com>
