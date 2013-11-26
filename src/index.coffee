{EventEmitter} = require 'events'
Scuttlebucket  = require 'scuttlebucket'
# DuplexStream = require 'duplex-stream'
Scuttlebutt    = require 'scuttlebutt'
{filter}       = require 'scuttlebutt/util'
through        = require 'through'
between        = require 'between'
RArray         = require 'r-array'
RValue         = require 'r-value'
# REdit        = require 'r-edit'
util           = require 'util'
hat            = require 'hat'
ss             = require 'stream-serializer'

# limiter = (delay = 100) ->
# 	times = {}
# 	stackback = null
# 	try
# 		throw new Error('catch this')
# 	catch e
# 		stackback = e
# 	stream = through (data) ->
# 		console.log 'got data in limiter:', data
# 		# debugger
# 		key = JSON.stringify data[0]
# 		now = new Date().getTime()
# 		if times[key]? and now - times[key] < delay
# 			console.log 'rejecting'
# 			return
# 		setTimeout (-> times[key] = undefined), delay
# 		times[key] = now
# 		@queue(data)
# 	stream.errback = stackback
# 	stream

order = (a, b) ->
	# timestamp, then source
	between.strord(a[1], b[1]) || between.strord(a[2], b[2])

dutyOfSubclass = (name) -> -> throw new Error("#{@constructor.name}.#{name} must be implemented")

# name should be the lowercased name of the class
class LBase extends Scuttlebutt
	@types: {}
	@register: (type) ->
		@types[type.name.toLowerCase()] = type

	@create: (name, args...) ->
		new @types[name]?(args...)

	pipe: (dest) ->
		@createReadStream().pipe(dest.createWriteStream())
		dest

	# map: (fn, args...) ->
	# 	newLive = new @constructor
	# 	# mapper = newLive.mapper.bind(newLive, fn, args...)
	# 	mapper = (update) -> newLive.mapper(update, fn, args...)

	# 	@createReadStream().pipe(ss.json(through((update) ->
	# 		@queue mapper(update)
	# 	))).pipe(newLive.createWriteStream())

	# 	newLive

	map: (fn, args...) ->
		newLive = new @constructor(@constructor.mapCreationArgs(fn, @creationArgs())...)

		@createReadStream().pipe(@constructor.mapper(fn, args...)).pipe(newLive.createWriteStream())

		newLive

	# What args to pass to the constructor when initially replicating it
	creationArgs: dutyOfSubclass 'creationArgs'
	# Map the creation args
	# @mapCreationArgs: dutyOfSubclass '@mapCreationArgs'

	# It must keep the custom property of any object that comes through
	# Returns: A through stream that takes json and transforms it
	# @mapper: dutyOfSubclass '@mapper'

	# Scuttlebutt Stuff
	applyUpdate: dutyOfSubclass 'applyUpdate'
	history: dutyOfSubclass 'history'

class LArray extends LBase
	constructor: (vals...) ->
		super()

		# @on 'old_data', (update) ->
		# 	console.log 'discarding update on LArray:', update

		@_sb   = new RArray
		@_db   = {}
		@_rack = hat.rack()

		@length = new LValue(0)

		@_hist       = {} # Key => The update that defined the key
		@_historyMap = {} # Key for unmapped update => Mapped update

		@_updateBuffer = {}
		@_sbKeys       = {}
		@_dbKeys       = {}

		# @_sb.on 'old_data', (update) ->
		# 	console.log 'discarding update on R-Array:', update

		@_sb.on 'update', (rawUpdate) =>
			update = {}

			for sbKey, key of rawUpdate
				update[key] = @_db[key]

			# console.log '_sb update:', update, rawUpdate

			for sbKey, key of rawUpdate
				if key?
					@_sbKeys[key] = sbKey
					@_dbKeys[sbKey] = key

			@emit 'update', update

			for sbKey, key of rawUpdate
				# console.log "#{sbKey} was set to #{key}, which is:", @_db[key]
				if key? and update[key]? # Update or insert
					if @_updateBuffer[key]?
						@emit 'update', @_sb.indexOfKey(sbKey), update[key], key, sbKey
					else
						@length.set @_sb.length

						@emit 'insert', @_sb.indexOfKey(sbKey), update[key], key, sbKey

					@_updateBuffer[key] = update[key]
				else # Delete
					key = @_dbKeys[sbKey]

					# if key?
					# 	console.log 'remove', key

					if @_updateBuffer[key]? || @_db[key]?
						@length.set @_sb.length

						@emit 'remove', @_sb.indexOfKey(sbKey), @_updateBuffer[key] || @_db[key], key, sbKey
						# delete @_updateBuffer[key]
						# delete @_sbKeys[key]
						# delete @_dbKeys[sbKey]
						# delete @_hist[key]
						# process.nextTick(((key) -> delete @_db[key]).bind(@, key))
					else
						# I think this occurs when it's replaying and it tries to delete an element that doesn't exist
						# console.log("the update is null and the buffer is null", update, rawUpdate, sbKey, key, @)
						# throw new Error('the update is null and the buffer is null')

			for sbKey, key of rawUpdate
				if !key?
					key = @_dbKeys[sbKey]
					delete @_dbKeys[sbKey]
					delete @_sbKeys[key]
					delete @_updateBuffer[key]
					delete @_hist[key]
					process.nextTick(((key) -> delete @_db[key]).bind @, key)

			return

		@_sb.on '_update', (update) =>
			@localUpdate [ 'a', update ]

		@push val for val in vals

	creationArgs: -> [] # @_sb.toJSON().map (key) => @_db[key]
	@mapCreationArgs: (fn, args) -> [] # args

	# Internal Functions
	_genId: -> @_rack()
	_register: (val, key = @_genId(), update = true) ->
		if update
			@localUpdate [ 'd', key, val.constructor.name.toLowerCase(), val.creationArgs() ]
		@_db[key] = val
		# I can't think of a way to remove this when the key is removed from the database
		# that doesn't include having an object storing all of them
		val.on '_update', (update) =>
			if @_db[key] == val
				# console.log "#{key} updated:", update
				@localUpdate [ 'c', key, update ]
		key
	_setIndex: (index, key) ->
		@_sb.set @_sb.keys[index], key
	_unset: (key) ->
		@_sb.unset @_sbKeys[key]

	push: (val) ->
		key = @_register val
		@_sb.push key
		@

	unshift: (val) ->
		key = @_register val
		@_sb.unshift key
		@

	# TODO: This shouldn't be this complicated
	get: (index) ->
		@_db[@_sb.get @_sb.keys[index]]

	pop: ->
		key = @_sb.pop()
		@_db[key]

	shift: ->
		key = @_sb.shift()
		@_db[key]

	remove: (index) ->
		@_sb.unset @_sb.keys[index]
		@
	
	forEach: (fn) ->
		for i in [0 .. @length.get() - 1]
			fn.call(@, @get(i), i)

		@

	each: (fn) -> @forEach(fn)

	# TODO: Figure out how to implement indexOf

	# mapper: (update, fn, subArgs = []) ->
	# 	if util.isArray(update)
	# 		data = update[0]

	# 		switch data[0]
	# 			when 'c'
	# 				childUpdate = [ data[2], update[1], update[2] ]

	# 				childUpdate = @_db[data[1]].mapper(fn, subArgs..., childUpdate)

	# 				[ [ 'c', data[1], childUpdate[0] ], childUpdate[1], childUpdate[2] ]
	# 			when 'd'
	# 				[ [ 'd', data[1], data[2], LBase.types[data[2]].mapCreationArgs(fn, data[3]) ], update[1], update[2] ]
	# 			else return update
	# 	else
	# 		return update

	@mapper: (fn, subArgs = []) ->
		db     = {}
		dbKeys = {}

		ss.json through (update) ->
			if Array.isArray update
				data = update[0]

				switch data[0]
					when 'c'
						# [ 'c', key, childData ]
						childUpdate = data[2].slice()
						childUpdate.args = [ data[1] ]
						childUpdate.custom = update

						if Array.isArray(update.args)
							childUpdate.args = childUpdate.args.concat(update.args)

						# console.log 'sending update to mapper:', childUpdate

						# childUpdate = db[data[1]]?.mapper(fn, subArgs..., childUpdate)
						db[data[1]]?.write JSON.stringify(childUpdate)

						# [ [ 'c', data[1], childUpdate[0] ], childUpdate[1], childUpdate[2] ]
					when 'd'
						# [ 'd', key, type, creationArgs ]

						mapper = LBase.types[data[2]].mapper(fn, subArgs...)
						mapper.on 'data', (update) =>
							@queue [ [ 'c', data[1], update ], update.custom[1][1], update.custom[1][2] ]

						db[data[1]] = mapper

						@queue [ [ 'd', data[1], data[2], LBase.types[data[2]].mapCreationArgs(fn, data[3], data[1]) ], update[1], update[2] ]
					else
						for sbKey, key of data
							if key?
								dbKeys[sbKey] = key
							else
								delete db[dbKeys[sbKey]]
								delete dbKeys[sbKey]

						@queue update
			else
				@queue update

	# Scuttlebutt Implementation
	history: (sources) ->
		hist = @_sb.history(sources).map (update) => @_historyMap["#{update[2]}-#{update[1]}"]

		for key, update of @_hist
			if !~hist.indexOf(update) && filter(update, sources)
				hist.push update

		for key, val of @_db
			hist = hist.concat val.history(sources).map((update) => @_historyMap["#{key}-#{update[2]}-#{update[1]}"])

		hist.filter(Boolean).sort order

	applyUpdate: (update) ->
		data = update[0]

		switch data[0]
			# Array
			when 'a'
				@_historyMap["#{data[1][2]}-#{data[1][1]}"] = update
				@_sb.applyUpdate(data[1])
			# DB
			when 'd'
				@_hist[data[1]] = update

				if !@_db[data[1]]?
					@_register LBase.create(data[2], data[3]...), data[1], false

				@emit '_register', data[1], @_db[data[1]]

				true
			# Child updates
			when 'c'
				@_historyMap["#{data[1]}-#{data[2][2]}-#{data[2][1]}"] = update

				if update[2] != @id
					@_db[data[1]]?._update(data[2])

				true

LBase.Array = LArray
LBase.register LArray

class LValue extends LBase
	constructor: (defaultVal, force = false) ->
		super()
		@_sb = new RValue
		@_sb.on 'update', (data) => @emit 'update', data
		@_sb.on '_update', (update) => @emit '_update', update

		# TODO: Fix this
		if defaultVal? # and force
			# @defaultVal = null
			@set defaultVal

	creationArgs: -> [@get()]
	@mapCreationArgs: (fn, args, subArgs...) -> [ fn(args[0], subArgs...) ]

	set: (newValue) ->
		if @get() != newValue
			@_sb.set newValue
		@

	get: -> @_sb.get()
		# if @_sb._history.length then @_sb.get() else @defaultVal

	# mapper: (update, fn) -> [ fn(update[0]), update[1], update[2] ]
	@mapper: (fn) ->
		ss.json through (update) ->
			# console.log 'update.args:', update.args

			@queue if Array.isArray(update)
				args = [ update[0] ]

				if Array.isArray(update.args)
					args = args.concat(update.args)

				newUpdate = [ fn(args...), update[1], update[2] ]
				newUpdate.custom = update.custom
				newUpdate
			else
				update

	# TODO: Unmap
	# TODO: Make this just a filter in a pipe
	# map: (fn) ->
	# 	val = new @constructor

	# 	update = =>
	# 		cb = val.set.bind(val)
	# 		res = fn(@get(), cb)

	# 		# TODO: Add support for promises
	# 		if res?
	# 			cb(res)

	# 	update()

	# 	@on 'update', update

	# 	val

	history: (sources) -> @_sb.history(sources)
	applyUpdate: (update) -> @_sb.applyUpdate(update)

	# createStream: ->
	# 	output = limiter()
	# 	input  = limiter()
	# 	input.pipe(@_sb.createStream()).pipe(output)
	# 	stream = new DuplexStream(output, input)
	# 	stream.resume()
	# 	stream
	# createReadStream: -> @_sb.createReadStream().pipe(limiter())
	# createWriteStream: ->
	# 	input = limiter()
	# 	input.pipe(@_sb.createWriteStream())
	# 	input

	# pipe: (val) ->
	# 	@on 'update', (d) -> val.set(d)
	# 	val.set(@get())

LBase.Value = LValue
LBase.register LValue

# # TODO: This doesn't work
# class Text extends Value
# 	constructor: ->
# 		@sb = new REdit
# 		@sb.on 'update', => @emit 'update', @get()
# 		@sb.on 'update', =>
# 			newValue = @sb.text()
# 			# console.log('newValue:', newValue)
# 			# if /^testing/.test(newValue) and newValue != 'testing'
# 			# 	if window?
# 			# 		throw new Error('why?')
# 			# 	else
# 			# 		console.trace('why?')

# 	set: (newValue) ->
# 		console.log('set text to ', newValue)
# 		@sb.text newValue
# 		@

# 	get: -> @sb.text()

# LBase.Text = Text
# LBase.register Text

module.exports = LBase