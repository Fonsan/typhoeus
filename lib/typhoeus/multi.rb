module Typhoeus
  class Multi
=begin
    # XXX add a finalisation to cleanup the multi? this is apparently essential
    def dealloc(multi)
      Curl.multi_cleanup(multi.handle)
    end
=end

    attr_reader :easy_handles

    def initialize
      Curl.init

      @handle = Curl.multi_init
      @active = 0
      @running = 0
      @easy_handles = []
    end

    def add(easy)
      raise "trying to add easy handle twice" if @easy_handles.include?(easy)
      easy.set_headers() if easy.headers.empty?

      code = Curl.multi_add_handle(@handle, easy.handle)
      raise RuntimeError.new("An error occured adding the handle: #{code}: #{Curl.multi_strerror(code)}") if code != :call_multi_perform and code != :ok

      do_perform if code == :call_multi_perform

      @active += 1
      @easy_handles << easy
      easy
    end

    def remove(easy)
      if @easy_handles.include?(easy)
        @active -= 1
        Curl.multi_remove_handle(@handle, easy.handle)
        @easy_handles.delete(easy)
      end
    end

    def perform
      while @active > 0
        run
        while @running > 0
          fd_read = Curl::FDSet.new
          fd_write = Curl::FDSet.new
          fd_excep = Curl::FDSet.new

          # get the curl-suggested timeout
          timeout = FFI::MemoryPointer.new(:long)
          code = Curl.multi_timeout(@handle, timeout)
          raise RuntimeError.new("an error occured getting the timeout: #{code}: #{Curl.multi_strerror(code)}") if code != :ok
          timeout = timeout.read_long
          if timeout == 0 # no delay
            run
            next
          elsif timeout < 0
            timeout = 1
          end

          # load the fd sets from the multi handle
          max_fd = FFI::MemoryPointer.new(:int)
          code = Curl.multi_fdset(@handle, fd_read, fd_write, fd_excep, max_fd)
          raise RuntimeError.new("an error occured getting the fdset: #{code}: #{Curl.multi_strerror(code)}") if code != :ok

          timeval = Curl::Timeval.new
          timeval[:sec] = timeout / 1000
          timeval[:usec] = (timeout * 1000) % 1000000

          code = Curl.select(max_fd.read_int + 1, fd_read, fd_write, fd_excep, timeval)
          raise RuntimeError.new("error on thread select: %d", FFI.errno) if code < 0

          run
        end
      end
      reset_easy_handles
    end

    def fire_and_forget
      run
    end

    # check for finished easy handles and remove from the multi handle
    def read_info
      msgs_left = FFI::MemoryPointer.new(:int)
      while not (msg = Curl.multi_info_read(@handle, msgs_left)).null?
        next if msg[:code] != :done

        easy = @easy_handles.find {|easy| easy.handle == msg[:easy_handle] }
        next if not easy

        response_code = FFI::MemoryPointer.new(:long)
        response_code.write_long(-1)
        Curl.easy_getinfo(easy.handle, :response_code, response_code)
        response_code = response_code.read_long
        remove(easy)

        easy.curl_return_code = msg[:data][:code]
        if easy.curl_return_code != 0 then easy.failure
        elsif (200..299).member?(response_code) or response_code == 0 then easy.success
        else easy.failure
        end
      end
    end

    def cleanup
      Curl.multi_cleanup(@handle)
      @active = 0
      @running = 0
      @easy_handles = []
    end

    def reset_easy_handles
      @easy_handles.dup.each do |easy|
        remove(easy)
        yield easy if block_given?
      end
    end

    private

    # called by perform and fire_and_forget
    def run
      begin code = do_perform end while code == :call_multi_perform
      raise RuntimeError.new("an error occured while running perform: #{code}: #{Curl.multi_strerror(code)}") if code != :ok
      read_info
    end

    def do_perform
      running = FFI::MemoryPointer.new(:int)
      code = Curl.multi_perform(@handle, running)
      @running = running.read_int
      code
    end
  end
end
