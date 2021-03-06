argv 	= require('optimist')
	.usage('A helper script to analyse the data acquired with Fujifilm BAS-5000 plate reader.\nUsage: $0 --mode <mode> --file <datafile> --output <output-file>.')
	.alias('mode', 'm')
	.describe('mode', 'Mode for the helper script to process the data. (kinetics)')
	.default('mode', 'kinetics')
	.demand('mode')
	.alias('file', 'f')
	.describe('file', 'Data file generated by the plate reader.')
	.demand('file')
	.alias('filetype', 't')
	.describe('filetype', "Type of the input file.")
	.default('filetype', 'csv')
	.demand('filetype')
	.alias('output', 'o')
	.describe('output', 'output file for the result. CSV format.')
	.argv

csv 	= require 'csv'
fs 		= require 'fs'
path 	= require 'path'

class PlateReaderHelper
	constructor: () ->
		@support_file_types 	= ['csv'] #['csv', 'raw', 'excel']
		@support_mode			= ['kinetics']
		@datafile				= null
		@filetype 				= 'csv'
		@output 				= null
		@ready					= false
		@error_msg				= []
		@mode 					= 'kinetics'
		@result 				= []
		@_result				= []

	raise_error: (msg) ->
		@error_msg.push msg

	error_exit: ->
		for errmsg in @error_msg
			console.error errmsg
		process.exit 1

	has_error: ->
		return if @error_msg.length then true else false

	error: (msg) ->
		@raise_error msg
		@error_exit()

	set_datafile: (data_file) ->
		fn = path.resolve data_file
		exists = fs.existsSync fn
		@datafile = if exists then fn else null
		@raise_error "File #{data_file} does not exist." unless exists

	set_outputfile: (output_file) ->
		fn = path.resolve output_file
		exists = fs.existsSync fn
		@output = if exists then null else fn
		@error "Output File #{output_file} has already existed." if exists

	set_filetype: (filetype) ->
		filetype = filetype.toLowerCase()
		@filetype = if filetype in @support_file_types then filetype else null
		@raise_error "Unsupport file type \"#{filetype}\"." if @filetype is null

	set_mode: (mode) ->
		mode = mode.toLowerCase()
		@mode = if mode in @support_mode then mode else null
		@raise_error "Unsupport operating mode \"#{mode}\"." if @mode is null

	_readfile: (cb, self = @) ->
		error_exit() if self.has_error()
		switch self.filetype
			when 'csv', 'raw'
				fh = fs.createReadStream self.datafile
				self.ready = true
				cb(fh)
			else
				self.raise_error "Unsupport file type \"#{@filetype}\"."
				cb(null)

	_loadfile: (cb, self = @) ->
		func_loadfile = (fh) ->
			self.error_exit() unless self.ready
			switch self.filetype
				when 'csv'
					csv()
						.from.stream(fh)
						.to.array((data, count) ->
							cb data
						)
						.on('error', (err) ->
							self.error err
						)
				else
					@error "Unsupport file type \"#{@filetype}\"."

		self._readfile func_loadfile, self

	_parsefile: (cb, self = @) ->
		func_parsefile = (data_array) ->
			self.result = []
			current_line = 0
			model_array = data_array[0][0].split(';')
			self.result['serial-number'] = model_array[1].split(':')[1].trim()
			self.result['firmware'] = model_array[2].split(':')[1].trim()
			self.result['xfluor4-version'] = model_array[3].split(':')[1].trim()
			self.result['date'] = data_array[1][5]
			self.result['time'] = data_array[2][5]

			_get_measurement_info = (col, s) ->
				parameter_name = col[0].toLowerCase().trim().replace(/\s+/g, '-').replace(/:$/, '')
				s.result[parameter_name] = col[5]
				switch parameter_name
					when 'measurement-wavelength'
						s.result[parameter_name] = [col[5], col[6]].join(' ')
					when 'plate-definition-file'
						s._result['plate-well-number'] = parseInt(s.result['plate-definition-file'].replace(/[^\d]/g,''))
						switch s._result['plate-well-number']
							when 6
								s._result['plate-max-x'] = 3
								s._result['plate-max-y'] = 2
							when 12
								s._result['plate-max-x'] = 4
								s._result['plate-max-y'] = 3
							when 24
								s._result['plate-max-x'] = 6
								s._result['plate-max-y'] = 4
							when 48
								s._result['plate-max-x'] = 8
								s._result['plate-max-y'] = 6
							when 96
								s._result['plate-max-x'] = 12
								s._result['plate-max-y'] = 8
							when 384
								s._result['plate-max-x'] = 24
								s._result['plate-max-y'] = 16
							else
								s._result['plate-max-x'] = 0
								s._result['plate-max-y'] = 0
						unless s._result['plate-well-range']
							s._result['plate-well-range'] = []
							s._result['plate-well-range']['x'] = []
							s._result['plate-well-range']['y'] = []
							s._result['plate-well-range']['x']['min'] = 1
							s._result['plate-well-range']['x']['max'] = s._result['plate-max-x']
							s._result['plate-well-range']['y']['min'] = 1
							s._result['plate-well-range']['y']['max'] = s._result['plate-max-y']
					when 'part-of-the-plate'
						[p_lt, p_rb] = s.result['part-of-the-plate'].split(' - ')
						s._result['plate-well-range'] = []
						s._result['plate-well-range']['x'] = []
						s._result['plate-well-range']['y'] = []
						s._result['plate-well-range']['x']['min'] = parseInt(p_lt.replace(/[^\d]/g,''))
						s._result['plate-well-range']['x']['max'] = parseInt(p_rb.replace(/[^\d]/g,''))
						s._result['plate-well-range']['y']['min'] = p_lt.replace(/\d/g,'').charCodeAt(0) - 'A'.charCodeAt(0)+1
						s._result['plate-well-range']['y']['max'] = p_rb.replace(/\d/g,'').charCodeAt(0) - 'A'.charCodeAt(0)+1
					when 'number-of-kinetic-cycles'
						s.mode = 'kinetics'
						s.result['number-of-kinetic-cycles'] = parseInt(s.result['number-of-kinetic-cycles'])
					when 'kinetic-interval'
						s.result['kinetic-interval'] = parseInt(s.result['kinetic-interval'])

			current_line = 4

			while data_array[current_line][0]
				_get_measurement_info data_array[current_line], self
				current_line++

			current_line++

			self._result['table'] = []
			switch self.mode
				when 'kinetics'
					# populate all kinetic tables

					for i in [1...self.result['number-of-kinetic-cycles']+1]
						cycle_no = parseInt(data_array[current_line][0].split(':')[1].trim())
						self._result['table'][cycle_no] = []
						self._result['table'][cycle_no]['cycle-number'] = cycle_no
						if cycle_no is 1
							self._result['table'][cycle_no]['time'] = 0
							self._result['table'][cycle_no]['time_unit'] = ''
						else
							time = parseInt(data_array[current_line][8])
							time_unit = data_array[current_line][9].trim().replace(/s$/,'')
							self._result['table'][cycle_no]['time'] = time
							self._result['table'][cycle_no]['time_unit'] = time_unit

						self._result['table'][cycle_no]['data'] = []
						for row_no_abs in [current_line+3...current_line+self._result['plate-max-y']+3] by 1
							row_no = row_no_abs - current_line - 3 
							self._result['table'][cycle_no]['data'][row_no] = (data_array[row_no_abs][col_no_abs] for col_no_abs in [1...self._result['plate-max-x']+1])

						current_line += 3 + self._result['plate-max-y'] + 1

					# process the result
					self.result['processed'] = []
					th = ['Cycle No.', 'Time', 'Time Unit']
					for row_no in [self._result['plate-well-range']['y']['min']...self._result['plate-well-range']['y']['max']+1]
						row_char = String.fromCharCode('A'.charCodeAt(0) + row_no - 1)
						for col_no in [self._result['plate-well-range']['x']['min']...self._result['plate-well-range']['x']['max']+1]
							th.push "#{row_char}#{col_no}"

					self.result['processed'].push th
					for i in [1...self.result['number-of-kinetic-cycles']+1]
						tr = []
						tb = self._result['table'][i]
						tr.push tb['cycle-number']
						tr.push tb['time']
						tr.push tb['time_unit']
						for row_no in [self._result['plate-well-range']['y']['min']...self._result['plate-well-range']['y']['max']+1]
							for col_no in [self._result['plate-well-range']['x']['min']...self._result['plate-well-range']['x']['max']+1]
								tr.push tb['data'][row_no-1][col_no-1]

						self.result['processed'].push tr






				else
					self.error "Unsupport mode!"

			cb self.result

		self._loadfile func_parsefile, self

	_formatoutput: (cb, self = @) ->
		func_formatoutput = (data) ->
			# do output part
			if self.output is null
				# output to screen
				output_str = []
				for k, v of data
					output_str.push [k.replace("/\-/g", ' '), v].join(": ") unless k is 'processed'

				output_str.push "---"
				for row in data['processed']
					output_str.push row.join("\t")




				console.log output_str.join('\n')
				cb data
			else
				# output to csv file
				data_array = []
				for k, v of data
					data_array.push [k, v].join(',') unless k is 'processed'
				data_array.push ""
				data_array.push 'Results'
				for row in data['processed']
					data_array.push row.join(",")

				fs.writeFile self.output, data_array.join("\n"), (err) ->
					if err
						self.error err
					else
						cb data

		self._parsefile func_formatoutput, self

	process: ->
		done = ->
			console.log "DONE!"

		@_formatoutput done, @	

main = ->
	prh = new PlateReaderHelper
	prh.set_datafile argv.file
	prh.set_filetype argv.filetype
	prh.set_outputfile argv.output if argv.output
	prh.set_mode argv.mode
	prh.process()



main()
