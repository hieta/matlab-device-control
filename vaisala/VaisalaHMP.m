% ----------------------------------------------------------------------------------------
% MATLAB class for Vaisala HMP230 series humidity and temperature transmitter 
% Tested models: HMP 233
% Disconnect the security lock jumper! Use HMP panel to set device configuration (see the manual)
% ----------------------------------------------------------------------------------------
% Author(s): Dr. Juha-Pekka Hieta (2024)
% Current version: 03/2025
% ----------------------------------------------------------------------------------------
% Compatibility: MATLAB 2022b or newer (uses 'dictionary')
% Functions return boolean false / true for error / success → Utilize in apps*
% ----------------------------------------------------------------------------------------
% Output format (see OUTPUT_FORMAT) examples:
% format                        output
% \UUU.UU\ \+TT.TT\\r           100.00 +99.99 <cr>
% \TTT.T\ \uu\\r\n              15.2 'C <cr><lf>
% \UUU.U\ \uuu\\+DD.D\ \uu\\r   46.9 %RH +10.8 'C <cr>
%
% Any text can be written in the command and it appears in the output:
% RH: \UUU.U\ T: \+TT.TT\\r --> RH: 54.0 T: +25 <cr>
%
% Symbols:
% \UU..UU\    relative humidity
% \TT..TT\    temperature
% \DD..DD\    dewpoint temperature
% \AA..AA\    absolute humidity
% \XX..XX\    mixing ratio
% \WW..WW\    wet bulb temperature
% \HH..HH\    enthalpy
% \uu..uu\    unit according to the preceding variable
% \n          line feed <lf>
% \r          carriage return <cr>
% \t          horizontal tabulation <ht> or <tab>
% \\          \
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% hmp = VaisalaHMP("COM21"); % Initialise Vaisala HMP transmitter object (COM port)
% hmp.PollingInterval = 10; % Optionally set polling interval and its unit, such as 's' for seconds (10 s)
% hmp.PollingIntervalUnit = 's';
% hmp.Connect(); % Create and open serialport/RS232 connection
% hmp.Initialize(); % Initialize all HMP default and restored settings, as also set in hmp object
% hmp.LogSet(path_logfile); % Optionally set log file path. This does not start logging!
% hmp.IsLogging = true; % Enable logging. Values are saved to a file set with .LogSet() each time the device values are read
% hmp.Measure(); % Read values
% hmp.Disconnect(); % Close serialport connection
% delete(hmp); % Delete the MATLAB object

classdef VaisalaHMP < handle
   
    properties (Constant, Hidden) % Change if necessary
        BAUD_RATE = 4800; % COM/Serial port settings
        DATA_BITS = 7;
        PARITY = "even";
        STOP_BITS = 1;
        FLOW_CONTROL = "none";
        D_TOGGLE = dictionary([0, 1], {'OFF', 'ON'}); % Use integers for ON/OFF values
        D_MEAS = dictionary(["RH", "T"], {[25; 28], [33; 36]}); % Measurement output value indeces for extracting measurement data
        D_MODES = dictionary(["Stop", "Run", "Poll"], {'STOP', 'RUN', 'POLL'}); % Stop = measurements output only by command, all commands can be used (including R/S for stop/start Run mode); Run = outputting automatically, only command S (=stop) can be used; Poll = read the manual
        D_CMD = dictionary(["PollingMode", "Read", "SetDate", "SetTime", "DataFormat", "DataUnits", "Echo", "EchoDate", "EchoTime", "PollingInterval", "Frost", "Start", "Stop", "DataAveraging"], {'SMODE', 'SEND', 'DATE', 'TIME', 'FORM', 'UNIT', 'ECHO', 'FDATE', 'FTIME', 'INTV', 'FROST', 'R', 'S', 'FILT'}); % All commands with simple English explanations
        D_UNITS = dictionary(["Metric", "Non-metric", "seconds", "minutes", "hours"], {'m', 'n', 's', 'min', 'h'}); % Metric (degC, etc.) or non-metric (degF, etc.) and polling interval time units
        D_MSG = dictionary(["Serial mode", "Frost", "Output units", "Output intrv", "Echo", "Form. date", "Form. time", "Filter"], {[17; -1], [18; -1], [17; -1], [19; -1], [18; -1], [18; -1], [18; -1], [18; -1]}); % Message char index range, -1 = end
        D_MSG_IGNORE = ["date is", "new date", "time is", "new time"];
        WAIT_TIME = 0.5; % Wait time in seconds between sent chained serial commands
    end

    properties
        IsConnected = false; % Is serial port connection open
        IsRunning = false; % Is automated, internally (HMP) timed polling event enabled
        IsLogging = false; % Is logging enabled
        HasEcho = false; % Measurement output format includes the command
        HasDate = true; % Measurement output format includes date (YYYY-MM-DD)
        HasTime = true; % Measurement output format includes time (HH:MM:SS)
        LogFile = []; % Log file ID to write data (NB! Not a path, see the LogSet, LogData, and LogClose functions)
        Device; % MATLAB serialport object (all commands are sent to Device)
        Port; % COM port, e.g., "COM5"
        Address = 0; % Address of the HMP transmitter when more than one HMP transmitter is connected to a serial bus
        Frost = false; % Frost OFF (false, dew point) or ON (true, frost point): Calculation mode within HMP device at dewpoint temperatures below 0 °C
        PollingMode = 'Stop'; % See D_MODES
        PollingInterval = 6; % Interval between polling events [0-255], use manually with app timers (D_MODE = STOP) or automatically with HMP's internal polling feature
        PollingIntervalUnit = 's'; % Time unit of PollingInterval, see D_UNITS
        DataFormat = 'RH: \UU.U\ T: \TT.T\\r\n'; % Sets the measurement data format that HMP returns as a message. For example, if HasDate and HasTime are enabled this becomes: YYYY-MM-DD HH:MM:SS RH: UU.U T: TT.T \r\n (<-- must match with the set terminator) 
        DataPattern = digitsPattern(4) + "-" + digitsPattern(2) + "-" + digitsPattern(2); % How to match the read measurement data/message received (match this with DataFormat), for example, with HasDate prefix
        DataUnits = 'Metric'; % See D_UNITS
        DataAveraging = 8; % The averaging time in seconds during which the individual measurement samples are integrated to get an averaged reading, 0 = disabled
        AirRH = 0; % Measured air relative humidity
        AirT = 0; % Measured air temperature
        AirDP = 0; % Calculated air dew point based on AirRH and AirT
        AirFP = 0; % Calculated air frost point based on AirRH and AirT
        LatestCommand; % Latest sent serial command
        LatestMessage; % Latest read serial message
    end

    methods

        function obj = VaisalaHMP(Port)
            if (nargin == 1)
                obj.Port = string(Port);
            else
                error("Please input one argument only: MATLAB COM port as a string (e.g., COM2)");
            end
        end

        function result = Connect(obj)
            result = false;
            PortsAvailable = obj.GetAvailableCOMs();
            if (~isempty(find(contains(PortsAvailable, obj.Port), 1))) % Check that COM port is available
                if (~obj.IsConnected)
                    try
                        obj.Device = serialport(obj.Port, obj.BAUD_RATE, DataBits=obj.DATA_BITS, Parity=obj.PARITY, StopBits=obj.STOP_BITS, FlowControl=obj.FLOW_CONTROL);
                        configureTerminator(obj.Device, "CR/LF", "CR/LF");
                        configureCallback(obj.Device, "terminator", @obj.ReadSerial);
                        obj.IsConnected = true;
                        result = true;
                    catch
                        obj.Device = [];
                        obj.IsConnected = false;
                        error("Failed to connect Vaisala HMP!");
                    end
                else
                    error("The following device is already connected: " + obj.Port);
                end
            else
                error("The following device is not available: " + obj.Port);
            end
        end

        function result = Disconnect(obj)
            result = false;
            if (obj.IsConnected)
                try
                    obj.LogClose();
                    delete(obj.Device);
                    obj.Device = [];
                    obj.IsConnected = false;
                    obj.IsLogging = false;
                    obj.LogFile = [];
                    obj.AirRH = 0;
                    obj.AirT = 0;
                    obj.AirDP = 0;
                    obj.AirFP = 0;
                    result = true;
                catch
                    error("Unable to disconnect device: " + obj.Port);
                end
            else
                error("Device is not connected");
            end
        end
        
        function ReadSerial(obj, source, event) % Processes the returned serial message together with the LatestCommand sent
            try
                %disp("READ") % Debugging
                message = strtrim(read(source, source.NumBytesAvailable, "char")); % Read returned message, remove CR (\r)
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
                return
            end
            obj.LatestMessage = message;
            % Check if the message can be ignored (D_MSG_IGNORE, includes no values of interest)
            for j = 1:length(obj.D_MSG_IGNORE)
                if (contains(message, obj.D_MSG_IGNORE{j}))
                    return
                end
            end
            % Find the dictionary key based on receive message
            key = ""; % Making sure key exists
            for j = 1:length(obj.D_MSG.keys)
                if (contains(message, obj.D_MSG.keys{j}))
                    key = obj.D_MSG.keys{j};
                    char_idx = obj.D_MSG{key};
                    if (char_idx(2) == -1)
                        data = message(char_idx(1):end);
                    else
                        data = message(char_idx(1):char_idx(2));
                    end
                    break
                end
            end
            % Update correct data based on read key
            switch key
                case "Serial mode" % Set output mode
                    obj.PollingMode = [upper(data(1)) lower(data(2:end))]; % See D_MODES, ensure the correct capitalization
                case "Frost" % Set/read calculation mode
                    if (strcmp(data, "ON"))
                        obj.Frost = true; % Frost point
                    else
                        obj.Frost = false; % Dew point
                    end
                case "Filter" % Measurement data averaging time
                    data = strtrim(data);
                    obj.DataAveraging = str2double(data);
                case "Output units" % Set/read data units 
                    if (strcmp(data, "metric"))
                        obj.DataUnits = "Metric";
                    else
                        obj.DataUnits = "Non-metric";
                    end
                case "Output intrv" % Set/read polling interval
                    data = strtrim(data);
                    vals = strsplit(data, ' '); % '100 min' --> '100' + 'min'
                    obj.PollingInterval = str2double(vals{1});
                    obj.PollingIntervalUnit = vals{2};
                case "Echo" % Set/read echo state
                    if (strcmp(data, "ON"))
                        obj.HasEcho = true;
                    else
                        obj.HasEcho = false;
                    end
                case "Form. time" % Set/read time echo 
                    if (strcmp(data, "ON"))
                        obj.HasTime = true;
                    else
                        obj.HasTime = false;
                    end
                case "Form. date" % Set/read date echo 
                    if (strcmp(data, "ON"))
                        obj.HasDate = true;
                    else
                        obj.HasDate = false;
                    end
                otherwise
                    if (~isempty(extract(message(1:10), obj.DataPattern))) % Match the first 10 chars (should be date)
                        obj.AirRH = str2double(message(obj.D_MEAS{"RH"}(1):obj.D_MEAS{"RH"}(2)));
                        obj.AirT = str2double(message(obj.D_MEAS{"T"}(1):obj.D_MEAS{"T"}(2)));
                        obj.AirDP = obj.CalcDewPoint(obj.AirRH, obj.AirT);
                        obj.AirFP = obj.CalcFrostPoint(obj.AirRH, obj.AirT);
                        if (obj.IsLogging)
                            obj.LogData();
                        end
                    else
                        warning("Unknown message received!");
                    end
            end
        end

        function result = Initialize(obj) % Configure all settings
            result = false;
            if (~obj.SetEcho(obj.HasEcho)) % Set echo off, otherwise all returned messages are incorrectly read
                error("Unable to disable echo!");
            end
            pause(obj.WAIT_TIME);
            if (~obj.SetCurrentMode()) % Set mode of polling
                error("Unable to set the mode of operation!");
            end
            pause(obj.WAIT_TIME);
            if (~obj.SetCurrentInterval()) % Set polling interval
                error("Unable to set the mode of operation!");
            end
            pause(obj.WAIT_TIME);
            if (~obj.SetCurrentAveraging()) % Set data averaging time (s)
                error("Unable to set the data averaging time!");
            end
            pause(obj.WAIT_TIME);
            if (~obj.SetDatetime()) % Set current date and time
                error("Unable to set the date and time!");
            end
            pause(obj.WAIT_TIME);
            if (~obj.SetDateEcho(obj.HasDate)) % Set output date echo as the set default
                error("Unable to set date echo!");
            end
            pause(obj.WAIT_TIME);
            if (~obj.SetTimeEcho(obj.HasTime)) % Set output time echo as the set default 
                error("Unable to set time echo!");
            end
            pause(obj.WAIT_TIME);
            if (~obj.SetUnits("Metric")) % Set current date and time
                error("Unable to set the unit format!");
            end
            pause(obj.WAIT_TIME);
            if (~obj.SetOutputFormat()) % Set output format for measurement data
                error("Unable to set output measurement data format!");
            end
            pause(obj.WAIT_TIME);
            result = true;
        end

        function result = GetEcho(obj)
            result = false;
            try
                obj.LatestCommand = obj.D_CMD{"Echo"};
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = SetEcho(obj, value) % 0 = off, 1 = on
            result = false;
            try
                obj.LatestCommand = [obj.D_CMD{"Echo"} ' ' obj.D_TOGGLE{value}];
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = GetMode(obj) % See D_MODES
            result = false;
            try
                obj.LatestCommand = obj.D_CMD{"PollingMode"};
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = SetCurrentMode(obj) % See D_MODES
            result = false;
            try
                obj.LatestCommand = [obj.D_CMD{"PollingMode"} ' ' obj.PollingMode];
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = SetMode(obj, value) % See D_MODES
            result = false;
            try
                obj.LatestCommand = [obj.D_CMD{"PollingMode"} ' ' obj.D_MODES{value}];
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = SetAveraging(obj, value) % See D_MODES
            result = false;
            try
                obj.LatestCommand = [obj.D_CMD{"DataAveraging"} ' ' num2str(value)];
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = SetCurrentAveraging(obj) % See D_MODES
            result = false;
            try
                obj.LatestCommand = [obj.D_CMD{"DataAveraging"} ' ' num2str(obj.DataAveraging)];
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = GetDateEcho(obj)
            result = false;
            try
                obj.LatestCommand = obj.D_CMD{"EchoDate"};
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = SetDateEcho(obj, value) % 0 = off, 1 = on
            result = false;
            try
                obj.LatestCommand = [obj.D_CMD{"EchoDate"} ' ' obj.D_TOGGLE{value}];
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end
        
        function result = GetTimeEcho(obj)
            result = false;
            try
                obj.LatestCommand = obj.D_CMD{"EchoTime"};
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = SetTimeEcho(obj, value) % 0 = off, 1 = on
            result = false;
            try
                obj.LatestCommand = [obj.D_CMD{"EchoTime"} ' ' obj.D_TOGGLE{value}];
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = SetDatetime(obj) % Sync current datetime with HMP
            result = false;
            t = char(datetime("now", "Format", "yyy-MM-dd HH:mm:ss"));
            try
                obj.LatestCommand = obj.D_CMD{"SetDate"};
                writeline(obj.Device, obj.LatestCommand);
                pause(obj.WAIT_TIME);
                obj.LatestCommand = t(1:10);
                writeline(obj.Device, obj.LatestCommand);
                pause(obj.WAIT_TIME);
                obj.LatestCommand = obj.D_CMD{"SetTime"};
                writeline(obj.Device, obj.LatestCommand);
                pause(obj.WAIT_TIME);
                obj.LatestCommand = t(12:19);
                writeline(obj.Device, obj.LatestCommand);
                pause(obj.WAIT_TIME);
                flush(obj.Device); % Something happens, don't know what, but this works
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = GetUnits(obj) % Metric or Non-metric
            result = false;
            try
                obj.LatestCommand = obj.D_CMD{"DataUnits"};
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = SetUnits(obj, value) % Metric or Non-metric
            result = false;
            try
                obj.LatestCommand = [obj.D_CMD{"DataUnits"} ' ' obj.D_UNITS{value}];
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = SetOutputFormat(obj)
            result = false;
            try
                obj.LatestMessage = '';
                obj.LatestCommand = [obj.D_CMD{"DataFormat"} ' ' obj.DataFormat];
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = GetInterval(obj) % Read polling interval and unit to obj.PollingInterval and obj.PollingInvervalUnit
            result = false;
            try
                obj.LatestCommand = obj.D_CMD{"PollingInterval"};
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end
        
        function result = SetCurrentInterval(obj) % Set polling interval based on obj.Values
            result = false;
            try
                obj.LatestCommand = [obj.D_CMD{"PollingInterval"} ' ' num2str(obj.PollingInterval) ' ' obj.PollingIntervalUnit]; % INTV time unit
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = SetInterval(obj, new_interval) % Set polling interval based on char array new_interval, e.g., '100 min'
            result = false;
            assert(ischar(new_interval), 'Interval must be a char array in VALUE UNIT format such as 10 s');
            try
                obj.LatestCommand = [obj.D_CMD{"PollingInterval"} ' ' new_interval]; % INTV time unit
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = LogSet(obj, log_path)
            result = false;
            try
                if (~exist(log_path, "file")) % Write a new header
                    obj.LogFile = fopen(log_path, "a");
                    fprintf(obj.LogFile, '%s\t\t%s\t%s\t%s\n', 'Datetime', 'RH (%)', ['T (' char(176) 'C)'], ['DP (' char(176) 'C)']);
                else
                    obj.LogFile = fopen(log_path, "a");
                end
                result = true;
            catch e
                obj.LogFile = [];
                obj.IsLogging = false;
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = LogData(obj) % Log current values to LogFile
            result = false;
            assert(~isempty(ismember(obj.LogFile, openedFiles)), "Unable to log data. Please set the LogFile first!");
            try
                fprintf(obj.LogFile, "%s\t%0.1f\t%0.1f\t%0.1f\n", datetime("now"), obj.AirRH, obj.AirT, obj.AirDP);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
        end

        function result = LogClose(obj) % Close the log file and set IsLogging
            result = false;
            obj.IsLogging = false;
            if (ismember(obj.LogFile, openedFiles))
                try
                    fclose(obj.LogFile);
                    obj.LogFile = [];
                    result = true;
                catch e
                    obj.LogFile = [];
                    fprintf(1, "Error identifier:\n%s\n", e.identifier);
                    fprintf(1, "Error message:\n%s\n", e.message);
                end
            else
                obj.LogFile = [];
            end
        end

        function result = Measure(obj) % Get a single measurement data
            result = false;
            try
                switch obj.PollingMode
                    case 'Stop'
                         obj.LatestCommand = obj.D_CMD{"Read"};
                    case 'Poll'
                         obj.LatestCommand = [obj.D_CMD{"Read"} ' ' obj.Address];
                    case 'Run' % Can only take obj.Run('Stop') command in this mode
                        result = true;
                        return
                end
                writeline(obj.Device, obj.LatestCommand);
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
            result = true;
        end

        function result = Run(obj, value) % 'Start' or 'Stop' internal polling: messages received automatically every obj.PollingInterval / obj.PollingIntervalUnit
            result = false;
            try
                obj.LatestCommand = obj.D_CMD{value};
                writeline(obj.Device, obj.LatestCommand);
                switch value
                    case 'Start'
                        obj.IsRunning = true;
                    case 'Stop'
                        obj.IsRunning = false;
                end
                result = true;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
            end
            result = true;
        end

    end

    methods (Static)

        function PortsAvailable = GetAvailableCOMs()
            PortsAvailable = serialportlist("available");
        end

        function DP = CalcDewPoint(RH, T)
            H = (log10(RH) - 2) / 0.4343 + (17.62 * T) / (243.12 + T); % Sonntag (1990), error: +/- 0.35 C for -45 C <= T <= 60 C
            DP = round(243.12 * H / (17.62 - H), 1);
        end

        function FP = CalcFrostPoint(RH, T)
            FP = dewpoint((273.15+T), RH/100, true, false) - 273.15;
        end

    end

end