module AssetCloud
  class S3Bucket < Bucket
    CacheControl = 'public, max-age=31557600'

    BOM_MARKERS = {
      'UTF-8'     => "\xEF\xBB\xBF".force_encoding('BINARY'),
      'UTF-32BE'  => "\x00\x00\xFE\xFF".force_encoding('BINARY'),
      'UTF-32LE'  => "\xFF\xFE\x00\x00".force_encoding('BINARY'),
      'UTF-16BE'  => "\xFE\xFF".force_encoding('BINARY'),
      'UTF-16LE'  => "\xFF\xFE".force_encoding('BINARY'),
    }

    def self.s3_connection
      AWS.eager_autoload!(AWS::S3) if Rails.application.config.eager_load

      AWS.config({
        access_key_id: config['access_key'],
        secret_access_key: config['secret_access_key'],
        use_ssl: true
      })
      AWS::S3.new(http_open_timeout: 20, http_read_timeout: 20)
    end

    def self.s3_bucket_name
      config['bucket']
    end

    #TODO: Build this up
    def self.default_s3_bucket(reload=false)
      if @s3_bucket && !reload
        @s3_bucket
      else
        @s3_bucket = s3_connection.buckets[s3_bucket_name]
      end
    end

    def self.s3_bucket
      @s3_bucket ||= default_s3_bucket
    end

    def ls(key = nil)
      objects = S3Bucket.s3_bucket.objects
      objects = objects.with_prefix(key) if key

      objects.map { |o| cloud[o.key] }
    end

    def read(key)
      data = S3Bucket.s3_bucket.objects[key].read
      encode_data(key, data)
    rescue AWS::Errors::Base
      raise AssetCloud::AssetNotFoundError, key
    end

    def write(key, data, options = {})
      options = options.merge(content_type: self.class.content_type_for(key), cache_control: CacheControl)
      object = S3Bucket.s3_bucket.objects[key]
      data_to_write = data.dup

      object.write(data_to_write, options)
    end

    def io(key, options={})
      object = S3Bucket.s3_bucket.objects[key]
      options = options.merge(content_type: self.class.content_type_for(key), cache_control: CacheControl)
      S3BucketIO.new(object.multipart_upload(options))
    end

    def delete(key)
      object = S3Bucket.s3_bucket.objects[key]

      object.delete rescue StandardError

      true
    end

    def stat(key)
      object = S3Bucket.s3_bucket.objects[key]
      metadata = object.head

      AssetCloud::Metadata.new(true, metadata[:content_length], nil, metadata[:last_modified])
    rescue AWS::S3::Errors::NoSuchKey
      AssetCloud::Metadata.new(false)
    end

    protected

    def self.content_type_for(key)
      ContentType.detect(key)
    end

    def encode_data(key, data)
      # Discussed in PR 11630
      if data.encoding == Encoding::ASCII_8BIT
        encode_data_from_bom(data) or encode_data_from_content_type(data, key) or data
      else
        Rails.logger.warn "[PublicS3Bucket#encode_data] Expected data to be ASCII-8BIT but was #{data.encoding} for #{key}"
        data
      end
    end

    def encode_data_from_bom(data)
      encoding = S3Bucket::BOM_MARKERS.find { |encoding, marker| data.starts_with?(marker) }.try(:first)
      return unless encoding
      data.force_encoding(encoding)
    end

    def encode_data_from_content_type(data, key)
      AnyToUTF8.to_utf8!(data)
    end

    def path_prefix
      @path_prefix ||= "s#{@cloud.url}"
    end
  end
end
