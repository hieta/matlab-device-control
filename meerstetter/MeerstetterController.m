% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% MATLAB class for Meerstetter's TEC controllers
% Supported models based on the communication protocol pdf:
% TEC-1089, 1090, 1091, 1092, 1122, 1123, 1161, 1162, 1163, 1166, 1167)
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Author(s): Dr. Juha-Pekka Hieta (2024)
% Current version: 11/2024
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Compatibility: MATLAB 2022b or newer (uses 'dictionary')
% For all parameter ids available, check: Meerstetter MeCom Communication Protocol 5136
% Written for a 1-channel model, you need to add parameters/functions to support the second channel
% Functions return boolean false / true for error / success --> Utilize in apps
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% tec = MeerstetterController("COM9", 1); % Initialize the Meerstetter TEC controller with its COM port and number of available channels (see the specs of your device)
% tec.Connect(); % Create and open serialport/RS232 connection
% tec.LogSet(tec_logfile_path); % Set the log file path. Does not start logging!
% tec.SetTargetTemp(10.0, 1); % Sets the target temperature of Channel/Instance 1 to 10 degrees Celcius
% tec.Enable(1); % Enable temperature control of Channel/Instance 1 --> Tries to reach obj.TempTarget
% tec.IsLogging = true; % Enable logging. Values are saved to a file set with .LogSet() each time the .Refresh() function is called
% tec.Refresh(1); % Update Channel/Instance 1 values (use with MATLAB timers)
% tec.Disable(1); % Disable temperature control
% tec.Disconnect(); % Close the serialport connection
% delete(tec); % Delete the MATLAB object

classdef MeerstetterController < handle
   
    properties (Constant, Hidden) % Change if necessary
        BAUD_RATE = 57600; % COM/Serial port settings
        DATA_BITS = 8;
        PARITY = "none";
        STOP_BITS = 1;
        FLOW_CONTROL = "none";
        D_PREFIX = dictionary(["Read", "Set"], {'#0015AA?VR', '#0015AAVS'}); % Command prefixes
        D_PARAM_IDS_FLOAT = dictionary(["Object_R", "Sink_R", "Target"], [1000, 1001, 3000]); % _R = read-only, returned values are 4-byte (32-bit) single-precision floats (MATLAB single)
        D_PARAM_IDS_INT = dictionary(["Status", "Output", "SensorType", "AutoReset"], [104, 2010, 4034, 6310]); % _R = read-only, returned values are (32-bit) integers (MATLAB double) 
        D_DEVICE_STATUS = dictionary([0, 1, 2, 3, 4, 5], {"Init", "Ready", "Run", "Error", "Boot", "Resetting"}); % Controller status
        D_SENSOR_TYPE = dictionary([0, 1, 2, 3, 4, 5, 6, 7, 8], {"Unknown Type", "PT100", "PT1000", "NTC18K", "NTC39K", "NTC56K", "NTC1M/NTC", "VIN1", "VIN1"});
        POLLING_INTERVAL = 10; % Wait time in seconds to use with app timers
        WAIT_TIME = 0.2; % Wait time in seconds between sent chained serial commands
    end

    properties
        IsConnected = false; % Is serial port connection open
        IsEnabled = false; % Is TEC enabled
        IsLogging = false; % Is logging enabled
        LogFile = []; % Log file ID to write data (NB! Not a path, see the LogSet, LogData, and LogClose functions)
        Device; % MATLAB serialport object (all commands are sent to Device)
        Channels = 1; % Number of TEC controller channels
        Port; % COM port, e.g., "COM5"
        TempTarget = 0; % Set target temperature in degrees Celcius
        TempObject = 0; % Temperature measured from the cooled/heated object
        TempSink = 0; % Temperature measured from the heatsink
        Status = "Offline"; % See the D_DEVICE_STATUS dictionary
        Error = false; % 
        LatestCommand; % Latest sent serial command in simple English (see D_PREFIX)
        LatestMessage; % Latest read serial response
    end

    methods

        function obj = MeerstetterController(Port, Channels) % String, integer
            if (nargin == 2)
                if (isstring(Port) && isnumeric(Channels))
                    obj.Port = Port;
                    obj.Channels = int32(Channels);
                else
                    error("Please input two arguments: MATLAB COM port as a string (COM2) and the number of channels as an integer (1).");
                end
            else
                error("Please input two arguments: MATLAB COM port as a string (COM2) and the number of channels as an integer (1).");
            end
        end

        function result = Connect(obj)
            result = false;
            PortsAvailable = obj.GetAvailableCOMs();
            % CHECK THAT THE DEVICE IS DISCONNECTED AND THE SERIAL IS AVAILABLE
            if (~isempty(find(contains(PortsAvailable, obj.Port), 1)))
                if (~obj.IsConnected)
                    try
                        obj.Device = serialport(obj.Port, obj.BAUD_RATE, DataBits=obj.DATA_BITS, Parity=obj.PARITY, StopBits=obj.STOP_BITS, FlowControl=obj.FLOW_CONTROL);
                        configureTerminator(obj.Device, "CR", "CR");
                        configureCallback(obj.Device, "terminator", @obj.ReadSerial);
                        obj.IsConnected = true;
                        result = true;
                    catch
                        obj.Device = [];
                        obj.IsConnected = false;
                        obj.TempTarget = 0;
                        obj.TempObject = 0;
                        obj.TempSink = 0;
                        obj.Status = "Offline";
                        obj.Error = false;
                        error("Failed to connect to Meerstetter TEC controller!");
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
                % Delete object
                try
                    obj.LogClose();
                    delete(obj.Device);
                    obj.Device = [];
                    obj.IsConnected = false;
                    obj.TempTarget = 0;
                    obj.TempObject = 0;
                    obj.TempSink = 0;
                    obj.Status = "Offline";
                    obj.Error = false;
                    result = true;
                catch
                    error("Unable to disconnect device: " + obj.Port);
                end
            else
                error("Device is not connected");
            end
        end
        
        function ReadSerial(obj, source, event) % Processes the returned serial message together with the LatestCommand sent
            % disp(source.NumBytesAvailable)
            % flush(source);
            % return
            % if (source.NumBytesAvailable < 11)
            %     disp("LESS THAN ELEVEN!")
            %     disp("Number of bytes: " + num2str(source.NumBytesAvailable))
            %     flush(source);
            %     return
            % end
            try
                message = strtrim(read(source, source.NumBytesAvailable, "char")); % Read returned message, remove CR (\r)
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
                return
            end
            obj.LatestMessage = message;
            % Check the sent command
            param_id = obj.HexToInt(obj.LatestCommand); % Get the sent parameter id
            % Find the dictionary key with the param_id got by flipping the keys/values of all dictionaries
            flipped_dicts = {dictionary(values(obj.D_PARAM_IDS_INT), keys(obj.D_PARAM_IDS_INT)), dictionary(values(obj.D_PARAM_IDS_FLOAT), keys(obj.D_PARAM_IDS_FLOAT))};
            for j = 1:length(flipped_dicts)
                try
                    cmd = lookup(flipped_dicts{j}, param_id);
                    break
                catch
                    continue
                end
            end
            % Message length tells what was returned
            if (length(message) == 11) % 11 = ACK signal = CRC returned back
                switch cmd
                    case "Output" % Controller enabled/disabled
                        obj.IsEnabled = obj.HexToInt(obj.LatestCommand(16:23)); % 0 = off, 1 = on
                    case "Target"
                        obj.TempTarget = obj.HexToCelcius(obj.LatestCommand(16:23)); % Target temperature set
                    case "AutoReset"
                        w = obj.GetStatus(1);
                    otherwise
                        warning("Unknown 11 char message received!");
                end
                obj.Error = false;
                return
            elseif (length(message) == 14) % Error
                obj.Error = true;
                return
            elseif (length(message) == 19) % Value returned
                % Match action with the sent command
                switch cmd
                    case "Status" % Get TEC status
                        obj.Status = obj.D_DEVICE_STATUS{obj.HexToInt(message)};
                        if (strcmp(obj.Status, "Run"))
                            obj.IsEnabled = true;
                        else
                            obj.IsEnabled = false;
                        end
                    case "Object_R" % Get object temperature
                        obj.TempObject = obj.HexToCelcius(message(8:15));
                    case "Sink_R" % Get object temperature
                        obj.TempSink = obj.HexToCelcius(message(8:15));
                    case "Target" % Target temperature read
                        obj.TempTarget = obj.HexToCelcius(message(8:15));
                    otherwise
                        warning("Unknown 19 char message received!");
                end
                obj.Error = false;
            else
                disp("ERROR")
                disp("Number of bytes: " + num2str(length(message)))
                flush(obj.Device);
                %error("Unknown message received!");
            end
        end

        function result = Refresh(obj, instance) % Update multiple values using the other functions consecutively
            result = false;
            if (~isempty(serialportfind(Port=obj.Port)))
                obj.IsConnected = true;
                if (~obj.GetStatus(instance))
                    obj.Status = -1;
                end
                pause(obj.WAIT_TIME);
                if (~obj.GetObjectTemp(instance))
                    obj.TempObject = -1;
                end
                pause(obj.WAIT_TIME);
                if (~obj.GetSinkTemp(instance))
                    obj.TempSink = -1;
                end
                pause(obj.WAIT_TIME);
                if (~obj.GetTargetTemp(instance))
                    obj.TempTarget = -1;
                end
                pause(obj.WAIT_TIME);
                if (obj.IsLogging)
                    obj.LogData();
                end
                result = true;
            else
                obj.IsConnected = false;
                delete(obj.Device);
                obj.Device = [];
                obj.Status = "Offline";
                error("Lost connection to TEC controller at port: " + obj.Port);
            end
        end
        
        function result = ValueRead(obj, pid, instance) % All commands with ?VR = ValueRead
            result = false;
            if (isnumeric(instance))
                instance = int2str(instance);
                if (length(instance) < 2)
                    instance = ['0' instance];
                end
            end
            cmd = [obj.D_PREFIX{"Read"} obj.DecToHex(pid, 4) instance]; % 4 char hex with reads
            checksum = obj.CRC16CCITT(cmd);
            cmd = obj.AddChecksum(cmd, checksum); % Append the command with checksum
            obj.LatestCommand = cmd;
            writeline(obj.Device, cmd);
            result = true;
        end
        
        function result = ValueSet(obj, pid, new_value, instance) % All commands with VS = ValueSet
            result = false;
            if (isnumeric(instance))
                instance = int2str(instance);
                if (length(instance) < 2)
                    instance = ['0' instance];
                end
            end
            % Check if temp value or other value
            if (obj.D_PARAM_IDS_FLOAT('Target') == pid) % Temps
                cmd = [obj.D_PREFIX{"Set"} obj.DecToHex(pid, 4) instance obj.CelciusToHex(new_value)];
            else
                cmd = [obj.D_PREFIX{"Set"} obj.DecToHex(pid, 4) instance obj.DecToHex(new_value, 8)]; % 8 char hex with sets
            end
            checksum = obj.CRC16CCITT(cmd);
            cmd = obj.AddChecksum(cmd, checksum); % Append the command with the calculated checksum, which will be returned back (see ReadSerial)
            if (length(cmd) == 27) % Example: #0015AAVS07DA01000000028F97, where '#0015AAVS' is the prefix, 07DA is the parameter id in hex, 01 is the instance, 00000002 is the set value, and 8F97 is the checksum
                obj.LatestCommand = cmd;
                writeline(obj.Device, cmd);
                result = true;
            else
                error("Value set command does not match with the requirements! Check the source code!");
            end
        end

        function result = Reset(obj) % Triggers a device reset, use when obj.Status == error (set)
            result = false;
            obj.ValueSet(obj.D_PARAM_IDS_INT("DeviceReset"), 1, '01'); % Writing 1 triggers the reset
            result = true;
        end

        function result = GetStatus(obj, instance) % Read the current device status, see D_DEVICE_STATUS dictionary (read)
            result = false;
            obj.ValueRead(obj.D_PARAM_IDS_INT('Status'), instance);
            result = true;
        end

        function result = GetObjectTemp(obj, instance) % Read the current object temperature (read)
            result = false;
            try
                obj.ValueRead(obj.D_PARAM_IDS_FLOAT('Object_R'), instance);
                result = true;
            catch
                error("Unable to read the object temperature!");
            end
        end

        function result = GetSinkTemp(obj, instance) % Read the current sink temperature (read)
            result = false;
            try
                obj.ValueRead(obj.D_PARAM_IDS_FLOAT('Sink_R'), instance);
                result = true;
            catch
                error("Unable to read the sink temperature!");
            end
        end

        function result = GetTargetTemp(obj, instance) % Read the target temperature (read)
            result = false;
            try
                obj.ValueRead(obj.D_PARAM_IDS_FLOAT('Target'), instance);
                result = true;
            catch
                error("Unable to read the target temperature!");
            end
        end

        function result = SetTargetTemp(obj, target_value, instance) % Set a new target temperature (set)
            result = false;
            try
                obj.ValueSet(obj.D_PARAM_IDS_FLOAT('Target'), target_value, instance);
                result = true;
            catch
                error("Unable to set the new target temperature!");
            end
        end
        
        function result = SetAutoReset(obj, t_seconds, instance) % If the system is in an error state, it restarts after this specified time
            result = false;
            try
                obj.ValueSet(obj.D_PARAM_IDS_INT('AutoReset'), t_seconds, instance);
                result = true;
            catch
                error("Unable to set the new target temperature!");
            end
        end

        function result = Enable(obj, instance) % Enable TEC --> Static ON (set)
            result = false;
            try
                obj.ValueSet(obj.D_PARAM_IDS_INT('Output'), 1, instance);
                obj.IsEnabled = true;
                result = true;
            catch
                error("Unable to enable TEC controller!");
            end
        end

        function result = Disable(obj, instance) % Disable TEC --> Static OFF (set)
            result = false;
            try
                obj.ValueSet(obj.D_PARAM_IDS_INT('Output'), 0, instance);
                obj.IsEnabled = false;
                result = true;
            catch
                error("Unable to disable TEC controller!");
            end
        end

        function result = LogSet(obj, log_path)
            result = false;
            try
                if (~exist(log_path, "file")) % Write a new header
                    obj.LogFile = fopen(log_path, "a");
                    fprintf(obj.LogFile, '%s\t\t%s\t%s\t%s\n', 'Datetime', ['Target (' char(176) 'C)'], ['Object (' char(176) 'C)'], ['Sink (' char(176) 'C)']);
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
                fprintf(obj.LogFile, "%s\t%0.1f\t\t%0.1f\t\t%0.1f\n", datetime("now"), obj.TempTarget, obj.TempObject, obj.TempSink);
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

    end

    methods (Static)

        function PortsAvailable = GetAvailableCOMs()
            PortsAvailable = serialportlist("available");
        end

        function h = CelciusToHex(n)
            h = upper(num2hex(single(n))); % Converts to single-precision and then to hex with uppercase chars
        end

        function v = HexToCelcius(chars)
            v = typecast(uint32(hex2dec(chars)),'single'); % 4 bytes
            v = double(v); % Return a double for app value fields
        end

        function v = HexToInt(chars) % Part of a char array (e.g., '#0015AB?VR04D201')
            if (chars(1) == '!') % Read / incoming
                v = hex2dec(chars(8:15)); % 32 bytes
            elseif (chars(1) == '#') % Sent / outgoing ('#')
                if (contains(chars, "?VR"))
                    v = hex2dec(chars(11:14)); % 32 bytes
                else
                    v = hex2dec(chars(10:13));
                end
            else % Plain hex (e.g., '03E8')
                v = hex2dec(chars);
            end
        end

        function h = DecToHex(n, n_hex_chars) % Ensure 4 or 8-char hexadecimals
            h = dec2hex(n);
            while (length(h) < n_hex_chars)
                h = ['0' h];
            end
        end

        function checksum = CRC16CCITT(data) % Calculate a 16-bit CRC-CCITT checksum
            checksum = -1;
            if (~ischar(data))
                error("Function takes a char array for 16-bit CRC-CCITT checksum calculation! Modify your input value.");
                return
            end
            try
                gx = zeros(1, 16); % 16 bits
                gx([13 6 1]) = 1;
                result = dec2bin(0, 16) - '0';
                for j = 1:length(data)
                    temp = dec2bin(data(j), 8) - '0';
                    for k = 1:8
                        if (result(16) ~= temp(k))
                            result(1:16) = [0 result(1:15)];
                            result = xor(result, gx);
                        else
        	                result(1:16) = [0 result(1:15)];
                        end
                    end
                end
                str = num2str(fliplr(result));
                checksum = dec2hex(bin2dec(str), 4);
            catch
                error("Unable to calculate 16-bit CRC-CCITT checksum for: " + data);
            end
        end

        function value = AddChecksum(value, checksum)
            if (ischar(value) && ischar(checksum))
                value = [value checksum]; % Return the command with 16-bit CRC-CCITT appended to the end
            else
                error("Unable to append the value with the 16-bit CRC-CCITT checksum! Both values need to be char arrays!");
            end
        end

    end

end