# encoding: utf-8

require "logstash/inputs/base"
require "logstash/namespace"
require "net/http"
require "uri"

# Stream events from the CouchDB _changes URI.
# Use event metadata to allow for upsert and
# document deletion.
class LogStash::Inputs::CouchDBChanges < LogStash::Inputs::Base
  config_name "couchdb_changes"
  milestone 1

  # IP or hostname of your CouchDB instance
  config :host, :validate => :string, :default => "localhost"

  # Port of your CouchDB instance.
  config :port, :validate => :number, :default => 5984

  # The CouchDB db to connect to.
  # Required parameter.
  config :db, :validate => :string, :required => true

  # Connect to CouchDB's _changes feed securely (via https)
  # Default: false (via http)
  config :secure, :validate => :boolean, :default => false
  
  # Path to a CA certificate file, used to validate certificates
  config :ca_file, :validate => :path

  # Username, if authentication is needed to connect to 
  # CouchDB
  config :username, :validate => :string, :default => nil

  # Password, if authentication is needed to connect to 
  # CouchDB
  config :password, :validate => :password, :default => nil
  
  # Logstash connects to CouchDB's _changes with feed=continuous
  # The heartbeat is how often (in milliseconds) Logstash will ping
  # CouchDB to ensure the connection is maintained.  Changing this 
  # setting is not recommended unless you know what you are doing.
  config :heartbeat, :validate => :number, :default => 1000

  # File path where the last sequence number in the _changes
  # stream is stored. If unset it will write to "$HOME/.couchdb_seq"
  config :sequence_path, :validate => :string

  # If unspecified, Logstash will attempt to read the last sequence number
  # from the `sequence_path` file.  If that is empty or non-existent, it will
  # begin with 0 (the beginning).
  # 
  # If you specify this value, it is anticipated that you will 
  # only be doing so for an initial read under special circumstances
  # and that you will unset this value afterwards.
  config :initial_sequence, :validate => :number
  
  # Preserve the CouchDB document revision "_rev" value in the
  # output.
  config :keep_revision, :validate => :boolean, :default => false
  
  # Future feature! Until implemented, changing this from the default 
  # will not do anything.
  #
  # Ignore attachments associated with CouchDB documents.
  config :ignore_attachments, :validate => :boolean, :default => true
  
  # Reconnect flag.  When true, always try to reconnect after a failure
  config :always_reconnect, :validate => :boolean, :default => true
  
  # Reconnect delay: time between reconnect attempts, in seconds.
  config :reconnect_delay, :validate => :number, :default => 10
  
  # Timeout: Number of milliseconds to wait for new data before
  # terminating the connection.  If a timeout is set it will disable
  # the heartbeat configuration option.
  config :timeout, :validate => :number

  public
  def register
    require "logstash/util/buftok"
    if @sequence_path.nil?
      if ENV["HOME"].nil?
        @logger.error("No HOME environment variable set, I don't know where " \
                      "to keep track of the files I'm watching. Either set " \
                      "HOME in your environment, or set sequence_path in " \
                      "in your Logstash config.")
        raise 
      end
      default_dir = ENV["HOME"]
      @sequence_path = File.join(default_dir, ".couchdb_seq")

      @logger.info("No sequence_path set, generating one...",
                   :sequence_path => @sequence_path)
    end

    @sequencedb   = SequenceDB::File.new(@sequence_path)
    @feed         = 'continuous'
    @include_docs = 'true'
    @path         = '/' + @db + '/_changes'

    @scheme = @secure ? 'https' : 'http'

    @sequence = @initial_sequence ? @initial_sequence : @sequencedb.read

    if !@username.nil? && !@password.nil?
      @userinfo = @username + ':' + @password.value
    else
      @userinfo = nil
    end
    
  end
  
  module SequenceDB
    class File
      def initialize(file)
        @sequence_path = file
      end

      def read
        ::File.exists?(@sequence_path) ? ::File.read(@sequence_path).chomp.strip : 0
      end

      def write(sequence = nil)
        sequence = 0 if sequence.nil?
        ::File.write(@sequence_path, sequence.to_s)
      end
    end
  end
  
  public
  def run(queue)
    buffer = FileWatch::BufferedTokenizer.new
    @logger.info("Connecting to CouchDB _changes stream at:", :host => @host.to_s, :port => @port.to_s, :db => @db)
    uri = build_uri
    Net::HTTP.start(@host, @port, :use_ssl => (@secure == true), :ca_file => @ca_file) do |http|
      request = Net::HTTP::Get.new(uri.request_uri)
      http.request request do |response|
        raise ArgumentError, "Database not found!" if response.code == "404"
        response.read_body do |chunk|
          buffer.extract(chunk).each do |changes|
            # If no changes come since the last heartbeat period, a blank line is
            # sent as a sort of keep-alive.  We should ignore those.
            next if changes.chomp.empty?
            event = build_event(changes)
            @logger.debug("event", :event => event.to_hash_with_metadata) if @logger.debug?
            decorate(event)
            unless event["empty"]
              queue << event
              @sequence = event['@metadata']['seq']
              @sequencedb.write(@sequence.to_s)
            end
          end
        end
      end
    end
  rescue Timeout::Error, Errno::EINVAL, Errno::ECONNRESET, EOFError, Errno::EHOSTUNREACH, Errno::ECONNREFUSED,
    Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError => e
    @logger.error("Connection problem encountered: Retrying connection in 10 seconds...", :error => e.to_s)
    retry if reconnect?
  rescue Errno::EBADF => e
    @logger.error("Unable to connect: Bad file descriptor: ", :error => e.to_s)
    retry if reconnect?
  rescue ArgumentError => e
    @logger.error("Unable to connect to database", :db => @db, :error => e.to_s)
    retry if reconnect?
  end
  
  private
  def build_uri
    options = {:feed => @feed, :include_docs => @include_docs, :since => @sequence}
    options = options.merge(@timeout ? {:timeout => @timeout} : {:heartbeat => @heartbeat})
    URI::HTTP.build(:scheme => @scheme, :userinfo => @userinfo, :host => @host, :port => @port, :path => @path, :query => URI.encode_www_form(options))
  end

  private
  def reconnect?
    sleep(@always_reconnect ? @reconnect_delay : 0)
    @always_reconnect
  end

  private
  def build_event(line)
    # In lieu of a codec, build the event here
    line = LogStash::Json.load(line)
    return LogStash::Event.new({"empty" => true}) if line.has_key?("last_seq")
    hash = Hash.new
    hash['@metadata'] = { '_id' => line['doc']['_id'] }
    if line['doc']['_deleted']
      hash['@metadata']['action'] = 'delete'
    else
      hash['doc'] = line['doc']
      hash['@metadata']['action'] = 'update'
      hash['doc'].delete('_id')
      hash['doc_as_upsert'] = true
      hash['doc'].delete('_rev') unless @keep_revision
    end
    hash['@metadata']['seq'] = line['seq']
    event = LogStash::Event.new(hash)
    @logger.debug("event", :event => event.to_hash_with_metadata) if @logger.debug?
    event
  end
end