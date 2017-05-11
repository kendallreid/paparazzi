#
# Paparazzi.js: A MJPG proxy for the masses
#
#   paparazzi = new Paparazzi(options)
#
#   paparazzi.on "update", (image) => 
#     console.log "Downloaded #{image.length} bytes"
#
#   paparazzi.start()
#

request = require 'request'
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0"

EventEmitter = require('events').EventEmitter

class Paparazzi extends EventEmitter

  @image = ''
  imageExpectedLength = -1

  constructor: (options) ->

    if not options.url?
      emitter.emit 'error',
        message: 'URL is not defined!'
    @options = options
    @memory = options.memory or 8388608 # 8MB

  start: ->

    # To use EventEmitter in the callback, we must save our instance 'this'
    emitter = @

    request.get(@options.url, @options).on 'response', (response) ->
      if response.statusCode != 200
        emitter.emit 'error',
          message: 'Server did not respond with HTTP 200 (OK).'
        return

      emitter.emit 'debug',
        message: response.headers['content-type']

      emitter.boundary = emitter.boundaryStringFromContentType response.headers['content-type']
      @data = ''

      response.setEncoding 'binary'
      response.on 'data', emitter.handleServerResponse
      response.on 'end', () ->
        emitter.emit 'error',
          message: "Server closed connection!"

  ###
  #
  # Find out the boundary string that delimits images.
  # If a boundary string is not found, it fallbacks to a default boundary.
  #
  ###
  boundaryStringFromContentType: (type) ->
    # M-JPEG content type looks like multipart/x-mixed-replace;boundary=<boundary-name>
    match = type.match(/multipart\/x-mixed-replace;\s*boundary=(.+)/)
    boundary = match[1] if match?.length > 1
    if not boundary?
      boundary = '--myboundary'
      @emit 'error',
        message: "Couldn't find a boundary string. Falling back to --myboundary."
    @emit 'debug',
      message: 'Boundary set to: ' + boundary
    boundary

  ###
  #
  # Handles chunks of data sent by the server and restore images.
  #
  # A MJPG image boundary typically looks like this:
  # --myboundary
  # Content-Type: image/jpeg
  # Content-Length: 64199
  # \r\n
  #
  ###
  handleServerResponse: (chunk) =>
    boundary_index = chunk.indexOf(@boundary)

    # Make sure we don't have a carry over boundary from the previous frame
    if @data
      previous_frame_boundary = @data.indexOf(@boundary)
      if previous_frame_boundary != -1
        #We know we are going to have headers that we need to scrub
        typeMatches = chunk.match /Content-Type:\s+image\/jpeg\s+/
        matches = chunk.match /Content-Length:\s+(\d+)\s+/
        if matches? and matches.length > 1
          newImageBeginning = chunk.indexOf(matches[0]) + matches[0].length
          @imageExpectedLength = matches[1]
          chunk = chunk.substring newImageBeginning

    # If a boundary is found, generate a new image from the data accumulated up to the boundary.
    # Otherwise keep eating. We will probably find a boundary in the next chunk.
    if boundary_index != -1

      # Append remaining data
      @data += chunk.substring 0, boundary_index
      # Now we got a new image
      @image = @data
      @emit 'update', @image

      # Start over
      @data = ''
      # Grab the remaining bytes of chunk
      remaining = chunk.substring boundary_index
      # Try to find the type of the next image
      typeMatches = remaining.match /Content-Type:\s+image\/jpeg\s+/
      # Try to find the length of the next image
      matches = remaining.match /Content-Length:\s+(\d+)\s+/

      if matches? and matches.length > 1
        # Grab length of new image and save first chunk
        newImageBeginning = remaining.indexOf(matches[0]) + matches[0].length
        @imageExpectedLength = matches[1]
        @data += remaining.substring newImageBeginning
      else if typeMatches?
        # If Content-Length is not present, but Content-Type is
        newImageBeginning = remaining.indexOf(typeMatches[0]) + typeMatches[0].length
        @data += remaining.substring newImageBeginning
      else
        @data += remaining
        @emit 'debug',
          message: 'Previous Image: ' + chunk.substring 0, boundary_index
        @emit 'debug',
          message: 'New Image: ' + remaining, remaining.length

        @emit 'debug',
          message: 'Current Boundary: ' + boundary_index
        newImageBeginning = boundary_index + @boundary.length
        @emit 'error',
          message: 'Boundary detected at end of frame. Copying to next frame.'
    else
      @data += chunk

    # Threshold to avoid memory over-consumption
    # E.g. if a boundary string is never found, 'data' will never stop consuming memory
    if @data.length >= @memory
      @data = ''
      @emit 'error',
        message: 'Data buffer just reached threshold, flushing memory'


module.exports = Paparazzi
