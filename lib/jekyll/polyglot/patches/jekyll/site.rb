require 'etc'

include Process
module Jekyll
  class Site
    attr_reader :default_lang, :languages, :exclude_from_localization, :lang_vars, :lang_from_path
    attr_accessor :file_langs, :active_lang

    def prepare
      @file_langs = {}
      @parallel_localization = config.fetch('parallel_localization', true)
      @lang_from_path = config.fetch('lang_from_path', false)
      @exclude_from_localization = config.fetch('exclude_from_localization', []).map do |e|
        if File.directory?(e) && e[-1] != '/'
          "#{e}/"
        else
          e
        end
      end
      @default_locale_in_subfolder = config.fetch('default_locale_in_subfolder', false)
      fetch_languages
    end

    def localization_directories
      if @default_locale_in_subfolder
        (@languages + [@default_lang]).uniq
      else
        @languages - [@default_lang]
      end
    end

    def lang_prefix(lang)
      if lang == @default_lang && !@default_locale_in_subfolder
        ''
      else
        "/#{lang}"
      end
    end

    # Public: Prefix a given path with the destination directory.
    #
    # paths - (optional) path elements to a file or directory within the
    #         destination directory
    #
    # Returns a path which is prefixed with the destination directory.
    #
    # Even though the destination is substituted during processing of each language,
    # we must also cover the case of default_loale_in_subfolder and files excluded
    # from localization.
    #
    # In this case in_dest_dir will be called with localized destination directory and
    # path to static file e.g. site.in_dest_dir("$SOURCE_DIR/_site/en", "/assets/image.png")
    # which should proceed to "$SOURCE_DIR/_site/assets/image.png"
    # 
    def in_dest_dir(*paths)
      if !paths.empty? && should_localize?(paths.last)
        paths.insert(paths.length-1, lang_prefix(@active_lang))
      end
      paths.reduce(dest) do |base, path|
        Jekyll.sanitized_path(base, path)
      end
    end

    def should_localize?(path)
      return false if @exclude_from_localization.nil?
      path = path.delete_prefix('/')
      !@exclude_from_localization.any? do |exclude_prefix|
        path.start_with?(exclude_prefix)
      end
    end

    def fetch_languages
      @default_lang = config.fetch('default_lang', 'en')
      @languages = config.fetch('languages', ['en']).uniq
      @keep_files += localization_directories
      if @default_locale_in_subfolder
        @keep_files += @exclude_from_localization
      end
      @active_lang = @default_lang
      @lang_vars = config.fetch('lang_vars', [])
    end

    alias process_orig process
    def process
      prepare
      all_langs = (@languages + [@default_lang]).uniq
      if @parallel_localization
        nproc = Etc.nprocessors
        pids = {}
        begin
          all_langs.each do |lang|
            pids[lang] = fork do
              process_language lang
            end
            while pids.length >= (lang == all_langs[-1] ? 1 : nproc)
              sleep 0.1
              pids.map do |lang, pid|
                next unless waitpid pid, Process::WNOHANG

                pids.delete lang
                raise "Polyglot subprocess #{pid} (#{lang}) failed (#{$?.exitstatus})" unless $?.success?
              end
            end
          end
        rescue Interrupt
          all_langs.each do |lang|
            next unless pids.key? lang

            puts "Killing #{pids[lang]} : #{lang}"
            kill('INT', pids[lang])
          end
        end
      else
        all_langs.each do |lang|
          process_language lang
        end
      end
      Jekyll::Hooks.trigger :polyglot, :post_write
    end

    alias site_payload_orig site_payload
    def site_payload
      payload = site_payload_orig
      payload['site']['default_lang'] = default_lang
      payload['site']['languages'] = languages
      payload['site']['active_lang'] = active_lang
      lang_vars.each do |v|
        payload['site'][v] = active_lang
      end
      payload
    end

    def process_language(lang)
      @active_lang = lang
      config['active_lang'] = @active_lang
      lang_vars.each do |v|
        config[v] = @active_lang
      end
      @file_langs = {}
      old_include = @include
      old_exclude = @exclude
      if @active_lang == @default_lang
        @include = @include.union(@exclude_from_localization)
      else
        @exclude = @exclude.union(@exclude_from_localization)
      end

      process_orig

      @include = old_include
      @exclude = old_exclude
    end

    def split_on_multiple_delimiters(string)
      delimiters = ['.', '/']
      regex = Regexp.union(delimiters)
      string.split(regex)
    end

    def derive_lang_from_path(doc)
      unless @lang_from_path
        return nil
      end

      segments = split_on_multiple_delimiters(doc.path)
      # loop through all segments and check if they match the language regex
      segments.each do |segment|
        if @languages.include?(segment)
          return segment
        end
      end

      # loop through all segments and check if they match the language regex
      segments.each do |segment|
        if @languages.include?(segment)
          return segment
        end
      end
      
      nil
    end

    # assigns natural permalinks to documents and prioritizes documents with
    # active_lang languages over others.  If lang is not set in front matter,
    # then this tries to derive from the path, if the lang_from_path is set.
    # otherwise it will assign the document to the default_lang
    def coordinate_documents(docs)
      regex = document_url_regex
      approved = {}
      docs.each do |doc|
        lang = doc.data['lang'] || derive_lang_from_path(doc) || @default_lang
        lang_exclusive = doc.data['lang-exclusive'] || []
        url = doc.url.gsub(regex, '/')
        page_id = doc.data['page_id'] || url
        doc.data['permalink'] = url if doc.data['permalink'].to_s.empty? && !lang.to_s.empty?

        # skip entirely if nothing to check
        next if @file_langs.nil?
        # skip this document if it has already been processed
        next if @file_langs[page_id] == @active_lang
        # skip this document if it has a fallback and it isn't assigned to the active language
        next if @file_langs[page_id] == @default_lang && lang != @active_lang
        # skip this document if it has lang-exclusive defined and the active_lang is not included
        next if !lang_exclusive.empty? && !lang_exclusive.include?(@active_lang)

        approved[page_id] = doc
        @file_langs[page_id] = lang
      end
      approved.values.each { |doc| assignPageRedirects(doc, docs) }
      approved.values.each { |doc| assignPageLanguagePermalinks(doc, docs) }
      approved.values
    end

    def assignPageRedirects(doc, docs)
      pageId = doc.data['page_id']
      if !pageId.nil? && !pageId.empty?
        lang = doc.data['lang'] || derive_lang_from_path(doc) || @default_lang
        redirectDocs = docs.select do |dd|
          doclang = dd.data['lang'] || derive_lang_from_path(dd) || @default_lang
          dd.data['page_id'] == pageId && doclang != lang && dd.data['permalink'] != doc.data['permalink']
        end
        redirects = redirectDocs.map { |dd| dd.data['permalink'] }
        doc.data['redirect_from'] = redirects
      end
    end

    def assignPageLanguagePermalinks(doc, docs)
      pageId = doc.data['page_id']
      if !pageId.nil? && !pageId.empty?
        unless doc.data['permalink_lang'] then doc.data['permalink_lang'] = {} end
        permalinkDocs = docs.select do |dd|
          dd.data['page_id'] == pageId
        end
        permalinkDocs.each do |dd|
          doclang = dd.data['lang'] || derive_lang_from_path(dd) || @default_lang
          doc.data['permalink_lang'][doclang] = dd.data['permalink']
        end
      end
    end

    # performs any necessary operations on the documents before rendering them
    def process_documents(docs)
      # return if @active_lang == @default_lang

      url = config.fetch('url', "")
      rel_regex = relative_url_regex(false)
      abs_regex = absolute_url_regex(url, false)
      non_rel_regex = relative_url_regex(true)
      non_abs_regex = absolute_url_regex(url, true)
      docs.each do |doc|
        unless lang_prefix(@active_lang).empty? then relativize_urls(doc, rel_regex) end
        correct_nonrelativized_urls(doc, non_rel_regex)
        unless url.empty?
          unless lang_prefix(@active_lang).empty? then relativize_absolute_urls(doc, abs_regex, url) end
          correct_nonrelativized_absolute_urls(doc, non_abs_regex, url)
        end
      end
    end

    # a regex that matches urls or permalinks with i18n prefixes or suffixes
    # matches /en/foo , .en/foo , foo.en/ and other simmilar default urls
    # made by jekyll when parsing documents without explicitly set permalinks
    def document_url_regex
      regex = ''
      (@languages || []).each do |lang|
        regex += "([\/\.]#{lang}[\/\.])|"
      end
      regex.chomp! '|'
      /#{regex}/
    end

    # a regex that matches relative urls in a html document
    # matches href="baseurl/foo/bar-baz" href="/foo/bar-baz" and others like it
    # avoids matching excluded files.  prepare makes sure
    # that all @exclude dirs have a trailing slash.
    def relative_url_regex(disabled = false)
      regex = ''
      unless disabled
        @exclude.union(@exclude_from_localization).each do |x|
          regex += "(?!#{x})"
        end
        @languages.each do |x|
          regex += "(?!#{x}\/)"
        end
      end
      start = disabled ? 'ferh' : 'href'
      %r{#{start}="?#{@baseurl}/((?:#{regex}[^,'"\s/?.]+\.?)*(?:/[^\]\[)("'\s]*)?)"}
    end

    # a regex that matches absolute urls in a html document
    # matches href="http://baseurl/foo/bar-baz" and others like it
    # avoids matching excluded files.  prepare makes sure
    # that all @exclude dirs have a trailing slash.
    def absolute_url_regex(url, disabled = false)
      regex = ''
      unless disabled
        @exclude.union(@exclude_from_localization).each do |x|
          regex += "(?!#{x})"
        end
        @languages.each do |x|
          regex += "(?!#{x}\/)"
        end
      end
      start = disabled ? 'ferh' : 'href'
      %r{(?<!hreflang="#{@default_lang}" )#{start}="?#{url}#{@baseurl}/((?:#{regex}[^,'"\s/?.]+\.?)*(?:/[^\]\[)("'\s]*)?)"}
    end

    def relativize_urls(doc, regex)
      return if doc.output.nil?

      modified_output = doc.output.dup
      modified_output.gsub!(regex, "href=\"#{@baseurl}/#{@active_lang}/" + '\1"')
      doc.output = modified_output
    end

    def relativize_absolute_urls(doc, regex, url)
      return if doc.output.nil?

      modified_output = doc.output.dup
      modified_output.gsub!(regex, "href=\"#{url}#{@baseurl}/#{@active_lang}/" + '\1"')
      doc.output = modified_output
    end

    def correct_nonrelativized_absolute_urls(doc, regex, url)
      return if doc.output.nil?

      modified_output = doc.output.dup
      modified_output.gsub!(regex, "href=\"#{url}#{@baseurl}/" + '\1"')
      doc.output = modified_output
    end

    def correct_nonrelativized_urls(doc, regex)
      return if doc.output.nil?

      modified_output = doc.output.dup
      modified_output.gsub!(regex, "href=\"#{@baseurl}/" + '\1"')
      doc.output = modified_output
    end
  end
end
