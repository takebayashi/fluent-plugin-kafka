# encode: utf-8
class Fluent::KafkaOutput < Fluent::BufferedOutput
  Fluent::Plugin.register_output('kafka', self)

  def initialize
    super
    require 'poseidon'
  end

  config_param :brokers, :string, :default => 'localhost:9092'
  config_param :zookeeper, :string, :default => nil
  config_param :default_topic, :string, :default => nil
  config_param :default_partition, :integer, :default => 0
  config_param :client_id, :string, :default => 'kafka'
  config_param :kafka_agg_max_bytes, :size, :default => 4*1024  #4k
  config_param :format, :string, :default => 'json'

  # poseidon producer options
  config_param :max_send_retries, :integer, :default => 3
  config_param :required_acks, :integer, :default => 0
  config_param :ack_timeout_ms, :integer, :default => 1500

  unless method_defined?(:log)
    define_method("log") { $log }
  end

  @seed_brokers = []

  def refresh_producer()
    if @zookeeper
      @seed_brokers = []
      z = Zookeeper.new(@zookeeper)
      z.get_children(:path => '/brokers/ids')[:children].each do |id|
        broker = Yajl.load(z.get(:path => "/brokers/ids/#{id}")[:data])
        @seed_brokers.push("#{broker['host']}:#{broker['port']}")
      end
      log.info "brokers has been refreshed via Zookeeper: #{@seed_brokers}"
    end
    begin
      if @seed_brokers.length > 0
        @producer = Poseidon::Producer.new(@seed_brokers, @client_id, :max_send_retries => @max_send_retries, :required_acks => @required_acks, :ack_timeout_ms => @ack_timeout_ms)
        log.info "initialized producer #{@client_id}"
      else
        log.warn "No brokers found on Zookeeper"
      end
    rescue Exception => e
      log.error e
    end
  end

  def configure(conf)
    super
    if @zookeeper
      require 'zookeeper'
      require 'yajl'
    else
      @seed_brokers = @brokers.match(",").nil? ? [@brokers] : @brokers.split(",")
      log.info "brokers has been set directly: #{@seed_brokers}"
    end
    @formatter = Fluent::Plugin.new_formatter(@format)
    @formatter.configure(conf)
  end

  def start
    super
    refresh_producer()
  end

  def shutdown
    super
  end

  def format(tag, time, record)
    [tag, time, record].to_msgpack
  end

  def write(chunk)
    records_by_topic = {}
    bytes_by_topic = {}
    messages = []
    messages_bytes = 0
    begin
      chunk.msgpack_each { |tag, time, record|
        topic = record['topic'] || @default_topic || tag

        records_by_topic[topic] ||= 0
        bytes_by_topic[topic] ||= 0

        record_buf = @formatter.format(tag, time, record)
        record_buf_bytes = record_buf.bytesize
        if messages.length > 0 and messages_bytes + record_buf_bytes > @kafka_agg_max_bytes
          @producer.send_messages(messages)
          messages = []
          messages_bytes = 0
        end
        messages << Poseidon::MessageToSend.new(topic, record_buf)
        messages_bytes += record_buf_bytes

        records_by_topic[topic] += 1
        bytes_by_topic[topic] += record_buf_bytes
      }
      if messages.length > 0
        @producer.send_messages(messages)
      end
      log.debug "(records|bytes) (#{records_by_topic}|#{bytes_by_topic})"
    end
  rescue Exception => e
    log.warn "Send exception occurred: #{e}"
    refresh_producer()
    # Raise exception to retry sendind messages
    raise e
  end
end
