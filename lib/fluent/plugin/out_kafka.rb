class Fluent::KafkaOutput < Fluent::Output
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
  config_param :output_data_type, :string, :default => 'json'
  config_param :output_include_tag, :bool, :default => false
  config_param :output_include_time, :bool, :default => false

  # poseidon producer options
  config_param :max_send_retries, :integer, :default => 3
  config_param :required_acks, :integer, :default => 0
  config_param :ack_timeout_ms, :integer, :default => 1500
  config_param :compression_codec, :string, :default => 'none'

  attr_accessor :output_data_type
  attr_accessor :field_separator

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
        @producer = Poseidon::Producer.new(@seed_brokers, @client_id, :max_send_retries => @max_send_retries, :required_acks => @required_acks, :ack_timeout_ms => @ack_timeout_ms, :compression_codec => @compression_codec.to_sym)
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
    if @compression_codec == 'snappy'
      require 'snappy'
    end
    require 'msgpack'

    @f_separator = case @field_separator
                   when /SPACE/i then ' '
                   when /COMMA/i then ','
                   when /SOH/i then "\x01"
                   else "\t"
                   end

    @custom_attributes = if @output_data_type =~ /^attr:(.*)$/
                           $1.split(',').map(&:strip).reject(&:empty?)
                         else
                           @formatter = Fluent::Plugin.new_formatter(@output_data_type)
                           @formatter.configure(conf)
                           nil
                         end

  end

  def start
    super
    refresh_producer()
  end

  def shutdown
    super
  end

  def parse_record(tag, time, record)
    if @custom_attributes.nil?
      @formatter.format(tag, time, record)
    else
      @custom_attributes.unshift('time') if @output_include_time
      @custom_attributes.unshift('tag') if @output_include_tag
      @custom_attributes.map { |attr|
        record[attr].nil? ? '' : record[attr].to_s
      }.join(@f_separator)
    end
  end

  def emit(tag, es, chain)
    begin
      chain.next
      es.each do |time,record|
        record['time'] = time if @output_include_time
        record['tag'] = tag if @output_include_tag
        topic = record['topic'] || self.default_topic || tag
        partition = record['partition'] || self.default_partition
        value = parse_record(tag, time, record)
        message = Poseidon::MessageToSend.new(topic, value)
        @producer.send_messages([message])
      end
    rescue Exception => e
      log.warn("Send exception occurred: #{e}")
      refresh_producer()
      raise e
    end
  end

end
