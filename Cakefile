childProcess = require 'child_process'

build = (watch, cb) ->
	run 'node', ['node_modules/coffee-script/bin/coffee', (if watch then '-cw' else '-c'), '-o', 'lib', 'src'], cb

run = (exec, args, cb) ->
	proc = childProcess.spawn exec, args
	proc.stdout.on 'data', (buffer) -> console.log buffer.toString()
	proc.stderr.on 'data', (buffer) -> console.log buffer.toString()
	proc.on 'exit', (status) ->
		process.exit(1) if status != 0
		cb() if typeof cb is 'function'

task 'build', 'build everything', -> build false
task 'build:watch', 'keep everything built', -> build true

task 'npm:install', 'install all the packages', -> run 'node', ['/usr/local/bin/npm', 'install']
task 'npm:install:watch', 'install all the packages', -> run 'node', ['node_modules/nodemon/nodemon.js', '-e', 'json', '/usr/local/bin/npm', 'install']