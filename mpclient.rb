# :title: Music Player Client for MPD in RBot
#
# Author:: Yohann MONNIER - Internethic
#
# Version:: 0.0.1
#
# License:: MIT license
#
# Thanks to mpd.rb/the Ruby MPD Library from which I Start

require 'pp'
require 'timeout'
require 'socket'
require "cgi"

class MusicPlayerPlugin < Plugin
  

  # MPD::SongInfo elements are:
  #
  # +file+ :: full pathname of file as seen by server
  # +album+ :: name of the album
  # +artist+ :: name of the artist
  # +dbid+ :: mpd db id for track
  # +pos+ :: playlist array index (starting at 0)
  # +time+ :: time of track in seconds
  # +title+ :: track title
  # +track+ :: track number within album
  #
  SongInfo = Struct.new("SongInfo", "file", "album", "artist", "dbid", "pos", "time", "title", "track")

  # MPD::Error elements are:
  #
  # +number+      :: ID number of the error as Integer
  # +index+       :: Line number of the error (0 if not in a command list) as Integer
  # +command+     :: Command name that caused the error
  # +description+ :: Human readable description of the error
  #
  Error = Struct.new("Error", "number", "index", "command", "description")


  # initialize configuration
  def initialize
  	super
  	
  	###############
  	##  SETTINGS ##
    ###############
    
  	#common regexps precompiled for speed and clarity
  	@@re = {
    	'ACK_MESSAGE'    => Regexp.new(/^ACK \[(\d+)\@(\d+)\] \{(.+)\} (.+)$/),
    	'DIGITS_ONLY'    => Regexp.new(/^\d+$/),
    	'OK_MPD_VERSION' => Regexp.new(/^OK MPD (.+)$/),  
    	'NON_DIGITS'     => Regexp.new(/^\D+$/),
    	'LISTALL'        => Regexp.new(/^file:\s/),
    	'PING'           => Regexp.new(/^OK/),
    	'PLAYLIST'       => Regexp.new(/^(\d+?):(.+)$/),
    	'PLAYLISTINFO'   => Regexp.new(/^(.+?):\s(.+)$/),
    	'STATS'          => Regexp.new(/^(.+?):\s(.+)$/),
    	'STATUS'         => Regexp.new(/^(.+?):\s(.+)$/),
  	}
  	
  	
	# SERVER PARAMETERS
	@mpd_host = 'ip-address-host'
	@mpd_port = 6600
	@authorized_network =  "ip-adress-autorized"
	@irc_shoutroom = "#irc-room"
	@password = nil

    # BEHAVIOR RELATED PARAMETERS (Modify if you understand what it does)
    @overwrite_playlist = true
    @allow_toggle_states = true
    @publish_status_in_shoutbox = false
    @debug_socket = false
    # if you set this parameter to true, commands will be accepted only from @authorized_network IP
    @authorized_network_filter = false
	@message_wrong_network = "Vous n'êtes pas connectés au bon réseau"

	# PLUGIN INSIDE PARAMETERS (Do not Modify)
    @socket = nil
    @mpd_version = nil
    @error = nil
    @volume_saved = nil	
    @current_song_in_progress = nil


	
	if ( @publish_status_in_shoutbox == true )
		@update_song_timerhelp = @bot.timer.add(1){
		    
		    song_listened = currentsong
		    if @current_song_in_progress.nil?
		    	@current_song_in_progress = song_listened
		    elsif @current_song_in_progress.file != song_listened.file
		    	@current_song_in_progress = song_listened
		    	
		        # BLOCK DISPLAY SONG
		  		if !(song_listened.album).nil?
		  			currentalbum = "#{song_listened.album} ->"
		  		else
		  			currentalbum = ""
		  		end
		  		if !(song_listened.title).nil?
		  			currenttitle = song_listened.title
		  		else
		  			currenttitle = "Unknown"
		  		end
		  		if !(song_listened.artist).nil?
		  			currentartist = song_listened.artist
		  		else
		  			currentartist = ""
		  		end
		  		if ( (song_listened.album).nil? && (song_listened.title).nil? )
		  			currenttitle = url_decode(song_listened.file)
		  		end    
		    	@bot.say @irc_shoutroom, "Listening :  #{currentalbum} #{currenttitle}. #{currentartist}"
		    end
			}
		end

  end
  

  def cleanup
    @bot.timer.remove(@update_song_timerhelp)
  end
  
  def close
    return nil unless is_connected?
    socket_puts("close")
    @socket = nil
  end
  
  # Private method for creating command lists.
  #
  def command_list_begin
    @command_list = ["command_list_begin"]
  end
  
  def url_decode(address)
  	clean_address = CGI::unescape(address)
  end


  # Wish this would take a block, but haven't quite figured out to get that to work
  # For now just put commands in the list.
  #
  def command(cmd)
    @command_list << cmd
  end

  # Closes and executes a command list.
  #
  def command_list_end
    @command_list << "command_list_end"
    sp = @command_list.flatten.join("\n")
    @command_list = []
    socket_puts(sp)
  end
  
  # Activate a closed connection. Will automatically send password if one has been set.
  #
  def connect
    begin
  		
    	unless is_connected? then
      		warn "connecting to socket" if @debug_socket
      		@socket = TCPSocket.new(@mpd_host, @mpd_port)
     	 	if md = @@re['OK_MPD_VERSION'].match(@socket.readline) then
        		@mpd_version = md[1]
        		unless @password.nil? then
          			warn  "connect sending password" if @debug_socket
          			@socket.puts("password #{@password}")
          			get_server_response
        		end
      		else
        		warn  "Connection error (Invalid Version Response)"
      		end
      		warn "connected to the server!" if @debug_socket
    	end
    	
    rescue Exception => e
      warn e.message
      warn e.backtrace.inspect
    end
  end
   

  


  # Turns off socket command debugging.
  #
  def debug_off
    @debug_socket = false
  end

  # Turns on socket command debugging (prints each socket command to STDERR as well as the socket)
  #
  def debug_on
    @debug_socket = true
  end
  
  # Private method for handling the messages the server sends. 
  #
  def get_server_response
    response = []
    while line = @socket.readline.chomp do
      # Did we cause an error? Save the data!
      if md = @@re['ACK_MESSAGE'].match(line) then
        @error = Error.new(md[1].to_i, md[2].to_i, md[3], md[4])
        raise "MPD Error #{md[1]}: #{md[4]}"
      end
      return response if @@re['PING'].match(line)
      response << line
    end
    return response
  end
  # Internal method for converting results from currentsong, playlistinfo, playlistid to
  # MPD::SongInfo structs
  #
  def hash_to_songinfo(h)
    SongInfo.new(h['file'],
                 h['Album'],
                 h['Artist'],
                 h['Id'].nil? ? nil : h['Id'].to_i, 
                 h['Pos'].nil? ? nil : h['Pos'].to_i, 
                 h['Time'],
                 h['Title'],
                 h['Track']
                 )
  end

  # Pings the server and returns true or false depending on whether a response was receieved.
  #
  def is_connected?
    return false if @socket.nil? || @socket.closed?
    warn "is_connected to socket: ping" if @debug_socket
    @socket.puts("ping")
    if @@re['PING'].match(@socket.readline) then
      return true
    end
    return false
  rescue
    return false
  end
  

  def mpd_version
    @mpd_version
  end
  
  # Send the password <i>pass</i> to the server and sets it for this MPD instance. 
  # If <i>pass</i> is omitted, uses any previously set password (see MPD#password=).
  # Once a password is set by either method MPD#connect can automatically send the password if
  # disconnected.  
  #
  def password(pass = @password)
    @password = pass
    socket_puts("password #{pass}")
  end
  
  # Pause playback on the server
  # Returns ('pause'|'play'|'stop'). 
  #
  def pause(value = nil)
    cstatus = status['state']
    return cstatus if cstatus == 'stop'

    if value.nil? && @allow_toggle_states then
      value = cstatus == 'pause' ? '0' : '1'
    end
    socket_puts("pause #{value}")
    status['state']
  end
  
  # Send a ping to the server and keep the connection alive.
  #
  def ping
    socket_puts("ping")
  end
  

  
  # Private method to convert playlistinfo style server output into MPD#SongInfo list
  # <i>re</i> is the Regexp to use to match "<element type>: <element>".
  # <i>response</i> is the output from MPD#socket_puts.
  def response_to_songinfo(re, response)
    list = []
    hash = {}
    response.each do |f|
      if md = re.match(f) then
        if md[1] == 'file' then
          if hash == {} then
            list << nil unless list == []
          else
            list << hash_to_songinfo(hash)
          end
          hash = {}
        end
        hash[md[1]] = md[2]
      end
    end
    if hash == {} then
      list << nil unless list == []
    else
      list << hash_to_songinfo(hash)
    end
    return list
  end
  
  # Pass a format string (like strftime) and get back a string of MPD information.
  #
  # Format string elements are: 
  # <tt>%f</tt> :: filename
  # <tt>%a</tt> :: artist
  # <tt>%A</tt> :: album
  # <tt>%i</tt> :: MPD database ID
  # <tt>%p</tt> :: playlist position
  # <tt>%t</tt> :: title
  # <tt>%T</tt> :: track time (in seconds)
  # <tt>%n</tt> :: track number
  # <tt>%e</tt> :: elapsed playtime (MM:SS form)
  # <tt>%l</tt> :: track length (MM:SS form)
  #
  # <i>song_info</i> can either be an existing MPD::SongInfo object (such as the one returned by
  # MPD#currentsong) or the MPD database ID for a song. If no <i>song_info</i> is given, all
  # song-related elements will come from the current song.
  #
  def strf(format_string, song_info = currentsong) 
    unless song_info.class == Struct::SongInfo
      if @@re['DIGITS_ONLY'].match(song_info.to_s) then
        song_info = playlistid(song_info)
      end
    end

    s = ''
    format_string.scan(/%[EO]?.|./o) do |x|
      case x
      when '%f'
        s << song_info.file.to_s

      when '%a'
        s << song_info.artist.to_s

      when '%A'
        s << song_info.album.to_s

      when '%i'
        s << song_info.dbid.to_s

      when '%p'
        s << song_info.pos.to_s
        
      when '%t'
        s << song_info.title.to_s

      when '%T'
        s << song_info.time.to_s

      when '%n'
        s << song_info.track.to_s

      when '%e'
        t = status['time'].split(/:/)[0].to_f
        s << sprintf( "%d:%02d", t / 60, t % 60 )

      when '%l'
        t = status['time'].split(/:/)[1].to_f
        s << sprintf( "%d:%02d", t / 60, t % 60 )

      else
        s << x.to_s

      end
    end
    return s
  end

  
  # Returns the types of URLs that can be handled by the server.
  #
  def urlhandlers
    handlers = []
    socket_puts("urlhandlers").each do |f|
      handlers << f if /^handler: (.+)$/.match(f)
    end
    return handlers
  end
  
  # Returns a hash containing various status elements:
  #
  # +audio+ :: '<sampleRate>:<bits>:<channels>' describes audio stream
  # +bitrate+ :: bitrate of audio stream in kbps
  # +error+ :: if there is an error, returns message here
  # +playlist+ :: the playlist version number as String
  # +playlistlength+ :: number indicating the length of the playlist as String
  # +repeat+ :: '0' or '1'
  # +song+ :: playlist index number of current song (stopped on or playing)
  # +songid+ :: song ID number of current song (stopped on or playing)
  # +state+ :: 'pause'|'play'|'stop'
  # +time+ :: '<elapsed>:<total>' (both in seconds) of current playing/paused song
  # +updating_db+ :: '<job id>' if currently updating db
  # +volume+ :: '0' to '100'
  # +xfade+ :: crossfade in seconds
  #
  def status
    s = {}
    socket_puts("status").each do |f|
      if md = @@re['STATUS'].match(f) then
        s[md[1]] = md[2]
      end
    end
    return s
  end
  
  
  # Sets random mode on the server, either directly, or by toggling (if
  # no argument given and @allow_toggle_states = true). Mode "0" = not 
  # random; Mode "1" = random. Random affects playback order, but not playlist
  # order. When random is on the playlist is shuffled and then used instead
  # of the actual playlist. Previous and next in random go to the previous
  # and next songs in the shuffled playlist. Calling MPD#next and then 
  # MPD#prev would start playback at the beginning of the current song.
  #
  def random(mode = nil)
    return nil if mode.nil? && !@allow_toggle_states
    return nil unless /^(0|1)$/.match(mode) || @allow_toggle_states
    if mode.nil? then
      mode = status['random'] == '1' ? '0' : '1'                                               
    end
    socket_puts("random #{mode}")
    status['random']
  end
  
  # Play previous song in the playlist. See note about shuffling in MPD#set_random.
  # Return songid as Integer
  #
  def previous(m, params)
	if ( whereami(m, params) )
  		connect unless is_connected?
    	socket_puts("previous")
   		mcurrentsong(m, params)
  	else
     	m.reply "#{@message_wrong_network}"
    end
  end
  
  # Play next song in the playlist. See note about shuffling in MPD#set_random
  # Returns songid as Integer.
  #
  def next(m, params)
	if ( whereami(m, params) )
  		connect unless is_connected?
    	socket_puts("next")
    	mcurrentsong(m, params)
  	else
     	m.reply "#{@message_wrong_network}"
    end
  end
  
  # Start playback of songs in the playlist with song at index 
  # <i>number</i> in the playlist.
  # Empty <i>number</i> starts playing from current spot or beginning.
  # Returns current song as MPD::SongInfo.
  #
  def play(m, params)
	if ( whereami(m, params) )
  		connect unless is_connected?
    	socket_puts("play #{params['number']}")
    	mcurrentsong(m, params)
  	else
     	m.reply "#{@message_wrong_network}"
    end
  end
  
  # Stops playback.
  # Returns ('pause'|'play'|'stop').
  #
  def stop(m, params)
	if ( whereami(m, params) )
  		connect unless is_connected?
    	socket_puts("stop")
    	m.reply "No Music" if ( status['state'] =="stop" )
  	else
     	m.reply "#{@message_wrong_network}"
    end
  end
  
  # Pause playback on the server
  # Returns ('pause'|'play'|'stop'). 
  #
  def pause(m, params)
  	if ( whereami(m, params) )
    	params['value'] = nil 
    	connect unless is_connected?
    	cstatus = status['state']
    	m.reply "No music" if cstatus == 'stop'

    	if params['value'].nil? && @allow_toggle_states then
    	  value = cstatus == 'pause' ? '0' : '1'
    	end
    	socket_puts("pause #{value}")
    	m.reply "en pause" if ( status['state'] == "pause" )
    	mcurrentsong(m, params) if ( status['state'] == "play" )
  	else
     	m.reply "#{@message_wrong_network}"
    end
  end
  
  # Set the volume to <i>volume</i>. Range is limited to 0-100. MPD#set_volume 
  # will adjust any value passed less than 0 or greater than 100.
  #
  def setvol(m, params)
  	if ( whereami(m, params) )
  		connect unless is_connected?
  		if (!params[:percent].nil?)
    		params[:percent] = 0 if params[:percent].to_i < 0
    		params[:percent] = 100 if params[:percent].to_i > 100
    		socket_puts("setvol #{params[:percent]}")
    	end
    	m.reply "Volume : #{status['volume']}%"
  	else
     	m.reply "#{@message_wrong_network}"
    end
  end

  def mute(m, params)
  	if ( whereami(m, params) )
  		if (status['volume'].to_i > 0)
  			m.reply "shut down sound" if @debug_socket
  			@volume_saved = status['volume']
  			params[:percent] = 0
  			setvol(m, params)
  		elsif (!@volume_saved.nil?)
  			m.reply "back to saved value #{@volume_saved}" if @debug_socket
  			params[:percent] = @volume_saved.to_i
  			setvol(m, params)
  		else
  			params[:percent] = 20
  			setvol(m, params)
  		end
  	else
     	m.reply "#{@message_wrong_network}"
    end
  end
  
  # Sends a command to the MPD server and optionally to STDOUT if
  # MPD#debug_on has been used to turn debugging on
  #
  def socket_puts(cmd)
    connect unless is_connected?
    warn "socket_puts to socket: #{cmd}" if @debug_socket
    @socket.puts(cmd)
    return get_server_response
  end
  
  def mversion(m, params)
  	if ( whereami(m, params) )
  		connect unless is_connected?
  		m.reply mpd_version
  	else
     	m.reply "#{@message_wrong_network}"
    end
  end
  
  # Returns an instance of Struct MPD::SongInfo.
  #
  def currentsong 	
  		connect unless is_connected?
    	response_to_songinfo(@@re['PLAYLISTINFO'],
                         socket_puts("currentsong")
       	                 )[0]
  end
  
  # Private method to convert playlistinfo style server output into MPD#SongInfo list
  # <i>re</i> is the Regexp to use to match "<element type>: <element>".
  # <i>response</i> is the output from MPD#socket_puts.
  def response_to_songinfo(re, response)
    list = []
    hash = {}
    response.each do |f|
      if md = re.match(f) then
        if md[1] == 'file' then
          if hash == {} then
            list << nil unless list == []
          else
            list << hash_to_songinfo(hash)
          end
          hash = {}
        end
        hash[md[1]] = md[2]
      end
    end
    if hash == {} then
      list << nil unless list == []
    else
      list << hash_to_songinfo(hash)
    end
    return list
  end

  def whereami(m, params)
	if ( @authorized_network_filter == true )
		if ( m.source.host == @authorized_network )
			return true
		else
			return false
		end
	else
		return true
	end
  end
  
  def mcurrentsong(m, params)
  	if ( whereami(m, params) )
  		currentsongobject = currentsong 
  		m.reply currentsongobject if @debug_socket
  		if !(currentsongobject.album).nil?
  			currentalbum = "#{currentsongobject.album} ->"
  		else
  			currentalbum = ""
  		end
  		if !(currentsongobject.title).nil?
  			currenttitle = currentsongobject.title
  		else
  			currenttitle = "Unknown"
  		end
  		if !(currentsongobject.artist).nil?
  			currentartist = currentsongobject.artist
  		else
  			currentartist = ""
  		end
  		if ( (currentsongobject.album).nil? && (currentsongobject.title).nil? )
  			currenttitle = url_decode(currentsongobject.file)
  		end
  	#{task_logger.task}
  	
  		m.reply "Listening :  #{currentalbum} #{currenttitle}. #{currentartist}"
  	else
     	m.reply "#{@message_wrong_network}"
    end
    
   end

  
  def help(plugin, topic="")
  case topic
    	when "mplay"
    		"mplay => Lance la musique"
    	when "mpause"
    		"mpause => Met en pause/Relance la musique"
    	when "mstop"
    		"mstop => Arrête la musique"
    	when "mprev"
    		"mprev => Va en arrière dans la playlist"
    	when "mnext"
    		"mnext => Va en avant dans la playlist"
    	when "msong"
    		"msong => Affiche la musique en cours de lecture"
    	when "mvolume"
    		"mvolume => Affiche le volume actuel, volume 35 => met le volume à 35%"
    	when "mute"
    		"mute => Coupe le volume / Reprend le volume à la valeur précédent le mute "
        else
    		"ECRIRE 'help musicplayer mplay|mpause|mstop|mprev|mnext|msong|mvolume|mute' pour avoir plus d'informations"
    	end
  end

end

plugin = MusicPlayerPlugin.new

plugin.map 'whereami',
  :action => 'whereami'
  
plugin.map 'mversion',
  :action => 'mversion'
  
plugin.map 'mute',
  :action => 'mute'
  
plugin.map 'mpcstart',
  :action => 'connect'
 
plugin.map 'mnext',
  :action => 'next'
  
plugin.map 'mprev',
  :action => 'previous'

plugin.map 'mplay',
  :action => 'play'

plugin.map 'mstop',
  :action => 'stop'
  
plugin.map 'mpause',
  :action => 'pause'

plugin.map 'msong',
  :action => 'mcurrentsong'
   
plugin.map 'mvolume :percent',
  :action => 'setvol'
  
plugin.map 'mvolume',
  :action => 'setvol'
  
 