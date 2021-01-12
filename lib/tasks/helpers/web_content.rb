
module Intrigue
module Task
module WebContent

  def html_dom_to_string(body)
    dom_string = ""
    document = Nokogiri::HTML(body);nil
    document.traverse do |node|
      next unless node.is_a?(Nokogiri::XML::Element)
      dom_string << "<#{node.name}>"
    end
  dom_string
  end

  # compare_html response.body_utf8.sanitize_unicode, e.details["hidden_response_data"]  
  def parse_html_diffs(texta, textb)
    # parse our content with Nokogiri
    our_doc = Nokogiri::HTML(texta)

    # parse them
    their_doc = Nokogiri::HTML(textb)

    # compare
    diffs = CompareXML.equivalent?(our_doc, their_doc, {
      verbose: true,
      ignore_text_nodes: true,
      ignore_comments: true
    })

    ###########################################
    # now filter down stuff we know we can skip 
    ##########################################
    if diffs.count > 0

      skip_regexes = [
        /csrf/,                             # generic csrf
        /authenticity_token/,               # generic csrf
        /asset_pipeline/,                   # generic asset pipeline
        /email-protection/,                 # cloudflare
        /__cf_email__/,                     # cloudflare
        /Ray ID/,                           # cloudflare 
        /heading-ray-id/,                   # cloudflare 
        /data-cf-beacom/,                   # cloudflare
        /wordpress\.com/,                   # wordpress
        /wp-content/,                       # wordpress 
        /wpcom_request_access_iframe/,      # wordpress
        /xmlrpc.php/                        # wordpress
      ]

      # Run through our diffs and see if these are things we know 
      # we can skip. all must be true in order to allow this to pass. 
      diffs = diffs.map do |d|
        
        matched_skip_regex = skip_regexes.map{ |s| 
          d if "#{d[:node1] || d[:node2]}".match(s) }.include?(d)
        
        out = nil if matched_skip_regex
        out = d if !matched_skip_regex

      out 
      end 

      diffs = diffs.flatten.uniq.compact 
    end

  diffs
  end

  def download_and_extract_metadata(uri,extract_content=true)

     begin
        # Download file and store locally before parsing. This helps prevent mime-type confusion
        # Note that we don't care who it is, we'll download indescriminently.
        filename = ""
        open("#{Dir::tmpdir}/#{rand(9999999999)}", "wb", {ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE}) do |file|
          open(uri) do |uri|
            file.write(uri.read)
            filename = file.path
          end
        end  

       mimetype = `file --brief --mime-type - < #{Shellwords.shellescape(filename)}`.strip

       ## Send to Apache Tika for analysis 
       @task_result.logger.log "Parsing #{filename}, mimetype: #{mimetype}"
       
       response = RestClient.put('http://127.0.0.1:9998/rmeta', File.open(filename,"rb").read, :accept => "application/json",:'content-type' => mimetype )
       metadata = JSON.parse(response).first

       # Handle audio files
       if metadata["Content-Type"] == "audio/mpeg" # Handle MP3/4
        
        # create people but unscoped since these files can come from anywhere
        create_unscoped_person_or_software(metadata["Author"], metadata["Last-Modified"], uri, {} ) if metadata["Author"]
        create_unscoped_person_or_software(metadata["creator"], metadata["Last-Modified"], uri) if metadata["creator"]
        create_unscoped_person_or_software(metadata["xmpDM:artist"], metadata["Last-Modified"], uri) if metadata["xmpDM:artist"]
         
       elsif metadata["Content-Type"] == "application/pdf" # Handle PDF
  
        # create people but unscoped since these files can come from anywhere
        create_unscoped_person_or_software(metadata["Author"], metadata["Last-Modified"], uri)  if metadata["Author"]
        create_unscoped_person_or_software(metadata["meta:author"], metadata["Last-Modified"], uri) if metadata["meta:author"]
        create_unscoped_person_or_software(metadata["xmp:CreatorTool"], metadata["Last-Modified"], uri) if metadata["xmp:CreatorTool"]
        create_unscoped_person_or_software(metadata["dc:creator"], metadata["Last-Modified"], uri)  if metadata["dc:creator"]
      
        # create an organization but it needs to be unscoped
        create_unscoped_organization(metadata["Company"], metadata["Last-Modified"], uri) if metadata["Company"]
       
       end

       # Look for entities in the text of the entity
       parse_entities_from_content(uri,metadata["X-TIKA:content"]) if extract_content

     rescue RuntimeError => e
      @task_result.logger.log_error "Runtime error: #{e}"
     rescue EOFError => e
       @task_result.logger.log_error "Unable to parse file: #{e}"
     rescue OpenURI::HTTPError => e     # don't die if we can't find the file
       @task_result.logger.log_error "Unable to download file: #{e}"
     rescue URI::InvalidURIError => e     # handle invalid uris
       @task_result.logger.log_error "Unable to download file: #{e}"
     rescue JSON::ParserError => e
       @task_result.logger.log_error "Unable to parse file: #{e}"
     end

   # return metadata
   metadata
   end

   def create_unscoped_person_or_software(create_string,last_modified, origin_uri, additional_details={})
      
      # skip if this is useless
      return nil if create_string == "user"

      to_create = { 
        "unscoped" => true,
        "name" => create_string, 
        "origin" => origin_uri,
        "modified" => last_modified }.merge(additional_details)

      # there's a bunch of stuff we know is just software
      if create_string.match(/adobe/i)                    ||  
         create_string.match(/apeosport-v/i)              ||
         create_string.match(/canon/i)                    ||
         create_string.match(/coreldraw/i)                ||
         create_string.match(/exe/i)                      ||
         create_string.match(/hewlett packard/i)          ||
         create_string.match(/hp/i)                       ||
         create_string.match(/lexmark/i)                  ||
         create_string.match(/microsoft/i)                || 
         create_string.match(/pdf/i)                      ||
         create_string.match(/postscript/i)               ||
         create_string.match(/pscript/i)                  ||
         create_string.match(/scansnap/i)                 ||
         create_string.match(/softquad/i)                 ||
         create_string.match(/snagit/i)                   ||
         create_string.match(/twain/i)                    ||
         create_string.match(/winver/i)                   ||
         create_string.match(/^word$/i)                   ||
         create_string.match(/workcentre/i)

        _create_entity "SoftwarePackage", to_create
      elsif create_string.match(/\d+/i) || create_string.length == 0
        # do nothing
      else
        _create_entity "Person", to_create
      end

   end

   def create_unscoped_organization(create_string,last_modified, origin_uri, additional_details={})
      to_create = { 
        "unscoped" => true,
        "name" => create_string, 
        "origin" => origin_uri,
        "modified" => last_modified }.merge(additional_details)

      _create_entity "Organization", to_create     
   end

   ###
   ### Entity Parsing
   ###
   def parse_entities_from_content(source_uri, content)
     parse_email_addresses_from_content(source_uri, content)
     parse_dns_records_from_content(source_uri, content)
     parse_phone_numbers_from_content(source_uri, content)
     #parse_uris_from_content(source_uri, content)
   end

   def parse_email_addresses_from_content(source_uri, content)

     @task_result.logger.log "Parsing text from #{source_uri}" if @task_result

     # Make sure we have something to parse
     unless content
       @task_result.logger.log_error "No content to parse, returning" if @task_result
       return nil
     end

     # Scan for email addresses
     addrs = content.scan(email_address_regex)
     addrs.each do |addr|
       details = {"name" => addr, "origin" => source_uri}
       x = _create_entity("EmailAddress", details) unless addr.match(/.png$|.jpg$|.gif$|.bmp$|.jpeg$/)
     end

   end

   def parse_dns_records_from_content(source_uri, content)

     @task_result.logger.log "Parsing text from #{source_uri}" if @task_result

     # Make sure we have something to parse
     unless content
       @task_result.logger.log_error "No content to parse, returning" if @task_result
       return nil
     end

     # Scan for dns records
     potential_dns_records = content.scan(dns_regex)

     potential_dns_records.compact.each do |potential_dns_record|

       # check that we have a valid TLD, to avoid stuff like image.png or file.css or page.aspx
       next unless parse_tld(potential_dns_record) && potential_dns_record.match(dns_regex)

       # TODO .. skip common javascript conventions
       next if potential_dns_record.match /[\(\)]+/
       next if potential_dns_record.match /\.analytics$/
       next if potential_dns_record.match /\.app$/
       next if potential_dns_record.match /\.call$/
       next if potential_dns_record.match /\.click$/
       next if potential_dns_record.match /\.data$/
       next if potential_dns_record.match /\.id$/
       next if potential_dns_record.match /\.map$/
       next if potential_dns_record.match /\.name$/
       next if potential_dns_record.match /\.next$/
       next if potential_dns_record.match /\.now$/
       next if potential_dns_record.match /\.open$/
       next if potential_dns_record.match /\.page$/
       next if potential_dns_record.match /\.prototype$/
       next if potential_dns_record.match /\.sc$/
       next if potential_dns_record.match /\.search$/
       next if potential_dns_record.match /\.show$/
       next if potential_dns_record.match /\.stream$/
       next if potential_dns_record.match /\.style$/
       next if potential_dns_record.match /\.target$/
       next if potential_dns_record.match /\.top$/
       next if potential_dns_record.match /\.video$/

      create_dns_entity_from_string potential_dns_record, nil, false, { "origin" => source_uri }
     end

   end

   def parse_phone_numbers_from_content(source_uri, content)

     @task_result.logger.log "Parsing text from #{source_uri}" if @task_result

     # Make sure we have something to parse
     unless content
       @task_result.logger.log_error "No content to parse, returning" if @task_result
       return nil
     end

     # Scan for phone numbers
     phone_numbers = content.scan(phone_number_regex)
     phone_numbers.each do |phone_number|
       x = _create_entity("PhoneNumber", { "name" => "#{phone_number[0]}", "origin" => source_uri})
     end
   end

   def parse_uris_from_content(source_uri, content)

     @task_result.logger.log "Parsing text from #{source_uri}" if @task_result

     # Make sure we have something to parse
     unless content
       @task_result.logger.log_error "No content to parse, returning" if @task_result
       return nil
     end

     # Scan for uris
     urls = content.scan(/https?:\/\/[\S]+/)
     urls.each do |url|
       parse_web_account_from_uri(url)
       _create_entity("Uri", {"name" => url, "uri" => url, "origin" => source_uri })
     end
   end

   def parse_web_account_from_uri(url)
     # Handle Twitter search results
     if url.match /https?:\/\/twitter.com\/.*$/
       account_name = url.split("/")[3]
       _create_normalized_webaccount "twitter", account_name, url
       
     # Handle Facebook public profile  results
     elsif url.match /https?:\/\/www.facebook.com\/(public|pages)\/.*$/
       account_name = url.split("/")[4]
       _create_normalized_webaccount "facebook", account_name, url

     # Handle Facebook search results
     elsif url.match /https?:\/\/www.facebook.com\/.*$/
       account_name = url.split("/")[3]
       _create_normalized_webaccount "facebook", account_name, url

     # Handle LinkedIn public profiles
     elsif url.match /^https?:\/\/www.linkedin.com\/in\/(\w).*$/
        account_name = url.split("/")[5]
        _create_normalized_webaccount "linkedin", account_name, url
     
       # Handle LinkedIn public profiles
     elsif url.match /^https?:\/\/www.linkedin.com\/in\/pub\/.*$/
         account_name = url.split("/")[5]
         _create_normalized_webaccount "linkedin", account_name, url

     # Handle LinkedIn public directory search results
     elsif url.match /^https?:\/\/www.linkedin.com\/pub\/dir\/.*$/
       account_name = "#{url.split("/")[5]} #{url.split("/")[6]}"
       _create_normalized_webaccount "linkedin", account_name, url

     # Handle LinkedIn world-wide directory results
     elsif url.match /^http:\/\/[\w]*.linkedin.com\/pub\/.*$/

     # Parses these URIs:
     #  - http://za.linkedin.com/pub/some-one/36/57b/514
     #  - http://uk.linkedin.com/pub/some-one/78/8b/151

       account_name = url.split("/")[4]
       _create_normalized_webaccount "linkedin", account_name, url

     # Handle LinkedIn profile search results
     elsif url.match /^https?:\/\/www.linkedin.com\/in\/.*$/
       account_name = url.split("/")[4]
       _create_normalized_webaccount "linkedin", account_name, url

     # Handle Google Plus search results
     elsif url.match /https?:\/\/plus.google.com\/.*$/
       account_name = url.split("/")[3]
       _create_normalized_webaccount "google", account_name, url

     # Handle Hackerone search results
     elsif url.match /https?:\/\/hackerone.com\/.*$/
       account_name = url.split("/")[3]
       _create_normalized_webaccount "hackerone", account_name, url

    # Handle Bugcrowd search results
    elsif url.match /https?:\/\/bugcrowd.com\/.*$/
      account_name = url.split("/")[3]
      _create_normalized_webaccount "bugcrowd", account_name, url
      

    end
   end


end
end
end
