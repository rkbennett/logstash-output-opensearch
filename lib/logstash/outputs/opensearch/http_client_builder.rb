# SPDX-License-Identifier: Apache-2.0
#
#  The OpenSearch Contributors require contributions made to
#  this file be licensed under the Apache-2.0 license or a
#  compatible open source license.
#
#  Modifications Copyright OpenSearch Contributors. See
#  GitHub history for details.

require 'cgi'
require "base64"

module LogStash; module Outputs; class OpenSearch;
  module HttpClientBuilder
    def self.build(logger, hosts, params)
      client_settings = {
        :pool_max => params["pool_max"],
        :pool_max_per_route => params["pool_max_per_route"],
        :check_connection_timeout => params["validate_after_inactivity"],
        :http_compression => params["http_compression"],
        :headers => params["custom_headers"] || {},
        :legacy => params["legacy_template"]
      }
      
      client_settings[:proxy] = params["proxy"] if params["proxy"]
      
      common_options = {
        :client_settings => client_settings,
        :metric => params["metric"],
        :resurrect_delay => params["resurrect_delay"]
      }

      if params["sniffing"]
        common_options[:sniffing] = true
        common_options[:sniffer_delay] = params["sniffing_delay"]
      end

      common_options[:timeout] = params["timeout"] if params["timeout"]
      common_options[:target_bulk_bytes] = params["target_bulk_bytes"]

      if params["path"]
        client_settings[:path] = dedup_slashes("/#{params["path"]}/")
      end

      common_options[:bulk_path] = if params["bulk_path"]
         dedup_slashes("/#{params["bulk_path"]}")
      else
         dedup_slashes("/#{params["path"]}/_bulk")
      end

      common_options[:sniffing_path] = if params["sniffing_path"]
         dedup_slashes("/#{params["sniffing_path"]}")
      else
         dedup_slashes("/#{params["path"]}/_nodes/http")
      end

      common_options[:healthcheck_path] = if params["healthcheck_path"]
         dedup_slashes("/#{params["healthcheck_path"]}")
      else
         dedup_slashes("/#{params["path"]}")
      end

      if params["parameters"]
        client_settings[:parameters] = params["parameters"]
      end

      logger.debug? && logger.debug("Normalizing http path", :path => params["path"], :normalized => client_settings[:path])

      client_settings.merge! setup_ssl(logger, params)
      common_options.merge! setup_basic_auth(logger, params)

      external_version_types = ["external", "external_gt", "external_gte"]
      # External Version validation
      raise(
        LogStash::ConfigurationError,
        "External versioning requires the presence of a version number."
      ) if external_version_types.include?(params.fetch('version_type', '')) and params.fetch("version", nil) == nil
 

      # Create API setup
      raise(
        LogStash::ConfigurationError,
        "External versioning is not supported by the create action."
      ) if params['action'] == 'create' and external_version_types.include?(params.fetch('version_type', ''))

      # Update API setup
      raise( LogStash::ConfigurationError,
        "doc_as_upsert and scripted_upsert are mutually exclusive."
      ) if params["doc_as_upsert"] and params["scripted_upsert"]

      raise(
        LogStash::ConfigurationError,
        "Specifying action => 'update' needs a document_id."
      ) if params['action'] == 'update' and params.fetch('document_id', '') == ''

      raise(
        LogStash::ConfigurationError,
        "External versioning is not supported by the update action."
      ) if params['action'] == 'update' and external_version_types.include?(params.fetch('version_type', ''))

      # Update API setup
      update_options = {
        :doc_as_upsert => params["doc_as_upsert"],
        :script_var_name => params["script_var_name"],
        :script_type => params["script_type"],
        :script_lang => params["script_lang"],
        :scripted_upsert => params["scripted_upsert"]
      }
      common_options.merge! update_options if params["action"] == 'update'

      create_http_client(common_options.merge(:hosts => hosts,
                                              :logger => logger,
                                              :auth_type => params["auth_type"]
                                              ))
    end

    def self.create_http_client(options)
      LogStash::Outputs::OpenSearch::HttpClient.new(options)
    end

    def self.setup_ssl(logger, params)
      params["ssl"] = true if params["hosts"].any? {|h| h.scheme == "https" }
      return {} if params["ssl"].nil?

      return {:ssl => {:enabled => false}} if params["ssl"] == false

      cacert, truststore, truststore_password, keystore, keystore_password, tls_client_cert, tls_client_key =
        params.values_at('cacert', 'truststore', 'truststore_password', 'keystore', 'keystore_password', 'tls_certificate', 'tls_key')

      if cacert && truststore
        raise(LogStash::ConfigurationError, "Use either \"cacert\" or \"truststore\" when configuring the CA certificate") if truststore
      end

      if (tls_client_cert && !tls_client_key)
        raise(LogStash::ConfigurationError, "\"tls_key\" is missing")
      end

      if (!tls_client_cert && tls_client_key)
        raise(LogStash::ConfigurationError, "\"tls_certificate\" is missing")
      end

      ssl_options = {:enabled => true}

      if cacert
        ssl_options[:ca_file] = cacert
      elsif truststore
        ssl_options[:truststore_password] = truststore_password.value if truststore_password
      end

      ssl_options[:truststore] = truststore if truststore
      if keystore
        ssl_options[:keystore] = keystore
        ssl_options[:keystore_password] = keystore_password.value if keystore_password
      end
      if (tls_client_cert && tls_client_key)
        ssl_options[:client_cert] = tls_client_cert
        ssl_options[:client_key] = tls_client_key
      end
      if !params["ssl_certificate_verification"]
        logger.warn [
                       "** WARNING ** Detected UNSAFE options in opensearch output configuration!",
                       "** WARNING ** You have enabled encryption but DISABLED certificate verification.",
                       "** WARNING ** To make sure your data is secure change :ssl_certificate_verification to true"
                     ].join("\n")
        ssl_options[:verify] = false
      end
      { ssl: ssl_options }
    end

    def self.setup_basic_auth(logger, params)
      user, password = params["user"], params["password"]
      
      return {} unless user && password && password.value

      {
        :user => CGI.escape(user),
        :password => CGI.escape(password.value)
      }
    end

    private
    def self.dedup_slashes(url)
      url.gsub(/\/+/, "/")
    end
  end
end; end; end
