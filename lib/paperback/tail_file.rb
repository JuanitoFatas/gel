require "strscan"
require "uri"
require "net/http"

class Paperback::TailFile
  # The number of redirects etc we'll follow before giving up
  MAXIMUM_CHAIN = 8

  # When attempting a partial file download, we'll back up by this many
  # bytes to ensure the preceding content matches our local file
  CONTENT_OVERLAP = 100

  # Only bother trying for a partial download if we have at least this
  # many bytes of local content. If we *don't* make a partial request,
  # 1) we're guaranteed not to need a second request due to bad overlap,
  # and 2) the response can be gzipped.
  PARTIAL_MINIMUM = 65536

  attr_accessor :uri, :pinboard, :filename
  def initialize(uri, pinboard)
    @uri = uri
    @pinboard = pinboard

    @filename = pinboard.filename(uri)
    @etag = pinboard.etag(uri)
  end

  def update
    force_reset = false
    uri = self.uri

    File.open(@filename, "a+b") do |f|
      f.seek(0, IO::SEEK_END)

      MAXIMUM_CHAIN.times do
        f.seek(0, IO::SEEK_SET) if force_reset

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          debug "GET #{uri}"
          request = Net::HTTP::Get.new(uri)

          requested_from = 0

          if f.pos > PARTIAL_MINIMUM
            requested_from = f.pos - CONTENT_OVERLAP
            request["Range"] = "bytes=#{requested_from}-"
            request["Accept-Encoding"] = "identity"
          else
            f.pos = 0
          end
          request["If-None-Match"] = @etag if @etag

          response = http.request(request)
          debug "HTTP #{response.code} (#{response.message}) #{uri}"

          case response
          when Net::HTTPNotModified
            pinboard.updated(uri, response["ETag"])

            return # no-op

          when Net::HTTPRequestedRangeNotSatisfiable
            # This should never happen, but sometimes does: either the
            # file has been rebuilt, and we should do a full fetch, or
            # we're ahead of the server (because an intermediate is
            # caching too aggressively, say), and we should do nothing.

            if response["Content-Range"] =~ /\Abytes \*\/(\d+)\z/
              current_length = $1.to_i

              debug "File is smaller than we expected: only #{current_length} bytes"

              # Back up a bit, and check whether the end matches what we
              # already have

              f.pos = current_length
              next
            else
              force_reset = true
              next
            end

          when Net::HTTPOK
            f.pos = 0
            f.truncate(0)
            f.write response.body

            pinboard.updated(uri, response["ETag"])

            return # Done

          when Net::HTTPPartialContent
            if response["Content-Range"] =~ /\Abytes (\d+)-(\d+)\/(\d+)\z/
              from, to, size = $1.to_i, $2.to_i, $3.to_i
            else
              # Not what we asked for
              debug "Bad response range"

              force_reset = true
              next
            end

            if from != requested_from
              # Server didn't give us what we asked for
              debug "Incorrect response range"

              force_reset = true
              next
            end

            if to - from + 1 != response.body.size
              # Server didn't give us what it claimed to
              debug "Bad response length"

              force_reset = true
              next
            end

            debug "Current file size is #{File.size(@filename)}"
            debug "Remote size is #{size}"

            f.pos = from

            if to < f.size
              # No new content, but check the overlap in case the file's
              # been reset

              overlap = f.read(to - from + 1)
              if response.body == overlap
                # Good overlap, but nothing new
                debug "Overlap is good, but no new content"

                pinboard.updated(uri, @etag) # keep old etag

                return # Done
              else
                # Bad overlap
                debug "Bad overlap on short response"

                force_reset = true
                next
              end
            else
              overlap = f.read
              if response.body[0, overlap.size] == overlap
                # Good overlap; use rest
                rest = response.body[overlap.size..-1]

                debug "#{overlap.size} byte overlap is okay"
                debug "Using remaining #{rest.size} bytes"

                f.write(rest)

                pinboard.updated(uri, response["ETag"])

                return # Done
              else
                # Bad overlap
                debug "Bad overlap on long response"

                force_reset = true
                next
              end
            end

          when Net::HTTPRedirection
            uri = URI(response["Location"])
            next

          else
            # splat
            response.value

            raise "Unexpected HTTP success code"
          end
        end
      end

      raise "Giving up after 8 requests"
    end
  end

  def debug(message)
    $stderr.puts message if $DEBUG
  end
end
