% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% MATLAB class for Bronkhorst's EL-FLOW Select controllers using ProPar ASCII protocol
% Tested models: F-201CV, F-202AV
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Author(s): Dr. Juha-Pekka Hieta (2024)
% Current version: 11/2024
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Compatibility: MATLAB 2022b or newer (uses 'dictionary')
% Many parts of the commands are currently preformed or assumed, for more sophisticated control you have to further develop the command string formation
% All parameters and settings are listed in Bronkhorst document 9.17.027AK (Date: 18-12-2023) (RS232 interface with ProPar protocol for digital multibus Mass Flow / Pressure instruments)
% Float numbers are in 32-bit single-precision floating-point format (IEEE-754), e.g. float 3F800000 = dec 1 (i.e. hex2dec does not give a correct answer)
% Functions return boolean false / true for error / success → Utilize in apps
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% elf = BronkhorstController("COM17", 1, 1); % Initialise a EL-FLOW controller (COM port, Node number, Process number: check/set these with FlowDDE)
% elf.Connect(); % Create and open serialport/RS232 connection
% elf.Refresh(); % Refresh values
% elf.LogSet(file_path); % Set log file path. This does not enable logging!
% elf.IsLogging = true; % Enable logging. Values are saved to a file set with .LogSet() each time the device values are read
% elf.WriteSetpoint(0); % Set the flow off
% elf.WriteSetpoint(6400); % Set the target flow value with an integer value (equals 20% output if the MaxSetpoint value of the controller is 32000)
% elf.WriteSetpoint(0.2); % Set the target flow value as a percentage (< 1) (equals 6400 if the MaxSetpoint value of the controller is 32000)
% elf.Measure(); % Read the current flow rate (use with MATLAB timers for example): the internal PID controller of the device should set the flow rate to the setpoint value
% elf.Disconnect(); % Close the serialport connection and reset values
% delete(elf); % Delete the MATLAB object

classdef BronkhorstController < handle
   
    properties (Constant, Hidden) % Change if necessary
        BAUD_RATE = 38400; % COM/Serial port settings
        DATA_BITS = 8;
        PARITY = "none";
        STOP_BITS = 1;
        FLOW_CONTROL = "none";
        D_PARAM_IDS_INT = dictionary(["Measure", "ReadSetpoint", "WriteSetpoint", "ReadControlMode", "WriteControlMode"], [20, 21, 21, 4, 4]); % Preformed parameter numbers, sum values of: [00 Parameter not chained] + [20 Parameter type ‘integer’] + [00 Parameter number (FBnr.) 0 (measure), 01 Parameter number (FBnr.) 1 (setpoint)]
        WAIT_TIME = 0.2; % Wait time in seconds between the sent chained serial commands
    end

    properties
        IsConnected = false; % Is serial port connection open
        IsLogging = false; % Is logging enabled
        LogFile = []; % Log file MATLAB ID to write data (NB! Not a path, see the LogSet(), LogData(), and LogClose() functions!)
        PollingInterval = 10; % Interval between polling events in seconds, use with MATLAB timers
        Device; % MATLAB serialport object (all serial commands are sent to Device)
        Port; % COM port, e.g. "COM5"
        Node = []; % Two digit char for FlowBus Node number (1 = '01'), use Bronkhorst FlowDDE to find it
        Process = []; % Two digit char for Process number (1 = '01')
        ControlMode = 0; % 0 = Bus/RS232, 1 = Analog input, etc. Read the manual and check your device's features.
        ErrorChecking = true; % Is the device sending messages back after the sent serial command (affects write commands), not yet truly implemented
        MaxFlowRate = 100; % Maximum flow rate output of the device [L/min]
        MaxSetpoint = 32000;  % The MaxSetpoint value is typically 100% flow, but the value read can sometimes be greater than 32000
        Setpoint = []; % Set flow setpoint value (always int): calculate percentages elsewhere
        Flow = []; % Measured flow value (int), calculate percentages etc. in the app
        FlowRate = []; % Measured flow rate [L/min] calculated based on the Flow, MaxSetpoint and MaxFlowRate values
        Error = false; % Error state
        LatestCommand; % Latest sent serial command
        LatestMessage; % Latest read serial response
    end

    methods

        function obj = BronkhorstController(Port, Node, Process) % Str, int, int ("COM2", 1, 1)
            if (nargin == 3)
                if ((ischar(Port) || isstring(Port)) && isnumeric(Node) && isnumeric(Process))
                    obj.Port = string(Port);
                    obj.Node = num2str(Node);
                    if (isscalar(obj.Node)) % One char
                        obj.Node = ['0' obj.Node];
                    end
                    obj.Process = num2str(Process); % '01' is the default for "Process not chained" (00) and "Process 1" (01)
                    if (isscalar(obj.Process)) % One char
                        obj.Process = ['0' obj.Process];
                    end
                else
                    error("Please input three arguments: MATLAB COM port as a string (COM2) and the Node and Process number as integers.");
                end
            else
                error("Please input three arguments: MATLAB COM port as a string (COM2) and the Node and Process number as integers.");
            end
        end

        function result = Connect(obj)
            result = false;
            PortsAvailable = obj.GetAvailableCOMs();
            if (~isempty(find(contains(PortsAvailable, obj.Port), 1))) % Check that the COM port is available
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
                        obj.Error = false;
                        error("Failed to connect to Bronhorst controller!");
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
                    obj.Flow = [];
                    obj.FlowRate = [];
                    obj.Setpoint = [];
                    obj.Error = false;
                    result = true;
                catch
                    error("Unable to disconnect device: " + obj.Port);
                end
            else
                error("Device is not connected");
            end
        end
        
        function result = Initialize(obj) % Configure all settings
            result = false;
            if (~obj.WriteControlMode(int32(obj.ControlMode))) % How to communicate with the device
                error("Unable to set the control mode!");
            end
            result = true;
        end

        function ReadSerial(obj, source, event) % Processes the returned serial message together with the LatestCommand sent
            try
                message = strtrim(read(source, source.NumBytesAvailable, "char")); % Read returned message, remove CR/LF (\r\n)
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
                return
            end
            obj.LatestMessage = message;
            % Parse the received message
            % message(1) = ':'
            % message(2:3) = message length (following this, index 4 ->)
            % The rest depends on the message length, see below
            n_char_pairs = str2double(message(2:3)); % E.g. '06' = (6 * 2 chars) follows from this point forward
            switch n_char_pairs
                case 1 % Errors
                    obj.Error = true;
                case 4 % Responses to write commands
                    % message(4:5) = node address
                    % message(6:7) = command status
                    % message(8:11) = value if status ok
                    if (strcmp(message(8:11), '0005')) % '0005' Setpoint write ok, check the sent command to modify correct values
                        switch obj.LatestCommand(10:11) % Match with the sent pid (two chars before the set value)
                            case '21' % Setpoint
                                obj.Setpoint = hex2dec(obj.LatestCommand(12:end));
                        end
                    elseif (strcmp(message(8:11), '0004')) % '0004' Control mode write ok, check the sent command to modify correct values
                        switch obj.LatestCommand(10:11) % Match with the sent pid (two chars before the set value)
                            case '04' % Control mode
                                obj.ControlMode = hex2dec(obj.LatestCommand(12:end));
                        end
                    else
                        error("Write command failed!");
                    end
                    obj.Error = false;
                case 5 % Responses to char read commands
                    % message(4:5) = node address
                    % message(6:7) = read command
                    % message(8:9) = process value
                    % message(10:11) = type of parameter / value returned ('04')
                    % message(12:13) = value returned ('00', '01', etc.)
                    switch obj.LatestCommand(14:15) % Match with the sent pid (two last chars)
                        case '04' % Control mode
                            obj.ControlMode = hex2dec(message(12:end));
                    end
                    obj.Error = false;
                case 6 % Responses to int/float read commands
                    % message(4:5) = node address
                    % message(6:7) = write command
                    % message(8:9) = process value
                    % message(10:11) = type of parameter / value returned
                    % message(12:15) = value
                    switch obj.LatestCommand(14:15) % Match with the sent pid (two last chars)
                        case '20' % Measure
                            obj.Flow = hex2dec(message(12:end));
                            obj.FlowRate = obj.Flow / obj.MaxSetpoint * obj.MaxFlowRate;
                            if (obj.IsLogging)
                                obj.LogData();
                            end
                        case '21' % Setpoint
                            obj.Setpoint = hex2dec(message(12:end));
                    end
                    obj.Error = false;
                otherwise
                    flush(obj.Device);
                    warning("Unknown message received, check your code!");
            end
        end

        function result = Reset(obj) % Add to app GUI to help with debugging
            result = false;
            flush(obj.Device);
            pause(obj.WAIT_TIME);
            result = true;
        end

        function result = Refresh(obj) % Update all read values
            result = false;
            if (~isempty(serialportfind(Port=obj.Port)))
                obj.IsConnected = true;
                if (~obj.ReadControlMode())
                    obj.Error = true;
                end
                if (~obj.Measure())
                    obj.Error = true;
                end
                pause(obj.WAIT_TIME);
                if (~obj.ReadSetpoint())
                    obj.Error = true;
                end
                result = true;
            else
                obj.IsConnected = false;
                delete(obj.Device);
                obj.Device = [];
                error("Lost connection to Bronkhorst controller at port: " + obj.Port);
            end
        end
        
        function result = ValueRead(obj, chained, pid) % All read commands via this function
            result = false;
            % Read message example: ': 06 01 04 01 21 01' without spaces, where
            %':' is a constant prefix
            % '06' is the constant read command length of 6 bytes (6 * 2 chars)
            % '01' is the obj.Node number
            % '04' is the constant command for 'read'
            % '01' is the sum of is_parameter_chained + obj.Process number
            % '21' is the parameter type (is_parameter_chained + parameter type + parameter index)
            % '01' is the obj.Process (process number only)
            if (chained) % Request for multiple parameter values (chained parameters), not impletemented yet
                % pid must be an array including all requested pid values
                % chained_process = obj.SumChars(is_chained, obj.Process); % (Is the command chained + Process number)
            else % Request for a single parameter value
                if (pid == 4) % Char commands, dirty fix
                    read_prefix = [':06' obj.Node '04' obj.Process '04' obj.Process]; % obj.Process equals chain+Process, Parameter type is not currently calculated
                    cmd = [read_prefix '04']; % Add the missing parameter number (pid): 2 chars from dictionary D_PARAM_IDS_INT
                else
                    read_prefix = [':06' obj.Node '04' obj.Process '21' obj.Process]; % obj.Process equals chain+Process, Parameter type is not currently calculated
                    cmd = [read_prefix num2str(pid)]; % Add the missing parameter number (pid): 2 chars from dictionary D_PARAM_IDS_INT
                end
                obj.LatestCommand = cmd;
                writeline(obj.Device, cmd);
            end
            result = true;
        end
        
        function result = ValueSet(obj, pid, new_value) % All write commands via this function
            result = false;
            if (obj.ErrorChecking) % Returns a message
                write_response = '01'; % Example: ':0601010121'
            else % Returns nothing
                write_response = '02'; % Example: ':0601020121'
            end
            % Different write commands have different number of bytes
            if (pid == 4) % Char writes, dirty fix
                write_prefix = [':05' obj.Node write_response obj.Process]; % Char writes have a hex value format '00' instead of '0000'
                hex_value = obj.DecToHex(new_value, 2); % Hex values '00'
                cmd = [write_prefix '04' hex_value]; % 2 chars pid, 4 chars new_value [pid = parameter type ('04') is not currently calculated]
            else % Int
                write_prefix = [':06' obj.Node write_response obj.Process];
                hex_value = obj.DecToHex(new_value, 4); % Hex values '0000'
                cmd = [write_prefix num2str(pid) hex_value]; % 2 chars pid, 4 chars new_value [pid = parameter type ('21') is not currently calculated]
            end
            obj.LatestCommand = cmd;
            writeline(obj.Device, cmd);
            result = true;
        end

        function result = ReadControlMode(obj) % Read control mode (0 = Modbus/RS232, 1 = Analog input ...)
            result = false;
            obj.ValueRead(false, obj.D_PARAM_IDS_INT('ReadControlMode'));
            result = true;
        end

        function result = WriteControlMode(obj, mode) % Set control mode (0 = Modbus/RS232, 1 = Analog input ...)
            result = false;
            assert(isinteger(mode), "Control mode value must be an integer!");
            obj.ValueSet(obj.D_PARAM_IDS_INT('WriteControlMode'), mode);
            result = true;
        end

        function result = Measure(obj) % 
            result = false;
            obj.ValueRead(false, obj.D_PARAM_IDS_INT('Measure')); % Parameter value to request, Is process chained (0), parameter type (is_parameter_chained? + parameter type (int) + parameter index)
            result = true;
        end

        function result = ReadSetpoint(obj) % 
            result = false;
            obj.ValueRead(false, obj.D_PARAM_IDS_INT('ReadSetpoint'));
            result = true;
        end

        function result = WriteSetpoint(obj, value) % Value or percentage of maximum (0 < value < 1)
            result = false;
            if (value > 0 && value <= 1.0) % Convert percentage to value
                value = value * obj.MaxSetpoint;
            end
            value = cast(value, "int32"); % Ensure integer for dec2hex in ValueSet
            obj.ValueSet(obj.D_PARAM_IDS_INT('WriteSetpoint'), value);
            result = true;
        end

        function result = LogSet(obj, log_path)
            result = false;
            try
                if (~exist(log_path, "file")) % Write a new header
                    obj.LogFile = fopen(log_path, "a");
                    fprintf(obj.LogFile, '%s\t\t%s\t%s\t%s\t%s\n', 'Datetime', 'Setpoint (value)', 'Setpoint (%)', 'Flow (value)', 'Flow rate (L/min)');
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
                fprintf(obj.LogFile, "%s\t%d\t\t\t%0.1f\t\t%d\t\t%0.1f\n", datetime("now"), obj.Setpoint, (obj.Setpoint/obj.MaxSetpoint*100), obj.Flow, obj.FlowRate);
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

        function v = HexToDouble(chars)
            v = typecast(uint32(hex2dec(chars)),'single'); % MATLAB single
            v = double(v); % MATLAB double
        end

        function h = DecToHex(n, n_hex_chars) % Ensure n-char hexadecimal
            h = dec2hex(n);
            while (length(h) < n_hex_chars)
                h = ['0' h];
            end
        end

        function s = SumChars(chars_1, chars_2) % '01' + '01' = '02', '00' + '01' = '01'
            assert(ischar(chars_1) && ischar(chars_2), "Function takes two char arrays!");
            assert(length(chars_1) == 2 && length(chars_2) == 2, "Char arrays must contain two chars!");
            val_1 = str2double(chars_1);
            val_2 = str2double(chars_2);
            val = val_1 + val_2;
            s = num2str(val);
            if (isscalar(s)) % Ensure that two chars will be returned
                s = ['0' s];
            end
        end

    end

end