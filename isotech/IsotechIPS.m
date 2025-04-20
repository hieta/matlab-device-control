% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% MATLAB class for ISO-TECH IPS power supplies using RS232/serialport
% Tested models: IPS-603 (60 V / 3.5 A), IPS-2010 (20 V / 10 A)
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Author(s): Dr. Juha-Pekka Hieta (2025)
% Current version: 03/2025
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Compatibility: MATLAB 2022b or newer (uses 'dictionary')
% ...
% Functions return boolean false / true for error / success --> Utilize in apps
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% ips = IsotechIPS("COM22", 3.5, 60, 210); % Initialise ISO-TECH IPS power supply with its COM port, MaxCurrent, MaxVoltage, and MaxLoad values
% ips.Connect(); % Create and open serialport/RS232 connection
% ips.Initialize(); % Set all object values to match with the PSU values
% ips.SetOutputVoltage(12.0); % Set output voltage to 12.0 V
% ips.SetCurrentLimit(1.0); % Limit maximum amperage to 1.0 A
% ips.On(); % Output on
% ips.Refresh(); % Read and refresh values (e.g., with app timers)
% ips.Off(); % Output off
% ips.ToggleRelay(); % Output off/on
% ips.Flush(); % Flush the serialport (minor error)
% ips.Reset(); % Try to reset the serial port connection (major error)
% ips.Disconnect(); % Close the serial port connection
% delete(ips); % Delete the MATLAB object

classdef IsotechIPS < handle
   
    properties (Constant, Hidden) % Change if necessary to preconfigure for your device
        BAUD_RATE = 2400; % COM/Serial port settings
        DATA_BITS = 8;
        PARITY = "none";
        STOP_BITS = 1;
        FLOW_CONTROL = "none";
        D_CMD = dictionary(["On", "Off", "ToggleRelay", "Status", "SetValue", "OutputCurrent", "CurrentLimit", "MaxCurrentLimit", "OutputVoltage", "VoltageLimit", "MaxVoltageLimit", "OutputLoad", "LoadLimit", "MaxLoadLimit", "KnobNormal", "KnobFine"], {'KOE', 'KOD', 'KO', 'L', 'S', 'A', 'I', 'IM', 'V', 'U', 'UM', 'W', 'P', 'PM', 'KN', 'KF'}); % All commands translated to English
        WAIT_TIME = 1; % Wait time in seconds between sent serial commands within class functions
    end

    properties % Changable from app
        IsConnected = false; % Is serial port connection open
        HasError = false; % Error state
        PollingInterval = 20; % Interval between polling events in seconds, use with app timers
        Device; % MATLAB serialport object (all commands are sent to Device)
        Port; % COM port, e.g., "COM10"
        Knob = []; % Device knob status: 'Normal' or 'Fine'
        Temperature = []; % Device temperature status: 'Normal' or 'Overheat'
        MaxCurrent = 0; % Maximum of the device, see the object constructor method for MaxValues
        MaxVoltage = 0; % Maximum of the device
        MaxLoad = 0; % Maximum of the device
        CurrentLimit = 0; % Output current limit (A), with two decimals (float)
        VoltageLimit = 0; % Output voltage limit (V), two digits only (integer)
        LoadLimit = 0; % Output load limit (W), three digits only (integer). Changes the current limit only, the voltage limit will remain unchanged!
        OutputCurrent = 0; % Read output current
        OutputVoltage = 0; % Read output voltage
        OutputLoad = 0; % Read output load
        RelayStatus = false; % Output enabled (true) or disabled (false)
        LatestCommand; % Latest sent serial command
        LatestMessage; % Latest read serial response
    end

    methods

        function obj = IsotechIPS(Port, MaxCurrent, MaxVoltage, MaxLoad)
            if (nargin == 4 && isnumeric(MaxCurrent) && isnumeric(MaxVoltage) && isnumeric(MaxLoad))
                obj.Port = string(Port);
                obj.MaxCurrent = MaxCurrent;
                obj.MaxVoltage = MaxVoltage;
                obj.MaxLoad = MaxLoad;
            else
                error("Please input four arguments: MATLAB COM port as a string (e.g., COM2) and maximum device output current (A), voltage (V), and load (W) as numerical values.");
            end
        end

        function result = Connect(obj)
            result = false;
            PortsAvailable = obj.GetAvailableCOMs();
            if (~isempty(find(contains(PortsAvailable, obj.Port), 1))) % Check that the COM port is available
                if (~obj.IsConnected)
                    try
                        obj.Device = serialport(obj.Port, obj.BAUD_RATE, DataBits=obj.DATA_BITS, Parity=obj.PARITY, StopBits=obj.STOP_BITS, FlowControl=obj.FLOW_CONTROL);
                        configureTerminator(obj.Device, "CR/LF", "CR");
                        configureCallback(obj.Device, "terminator", @obj.ReadSerial);
                        obj.IsConnected = true;
                        obj.HasError = false;
                        result = true;
                    catch
                        obj.Device = [];
                        obj.IsConnected = false;
                        obj.HasError = true;
                        error("Failed to connect ISO-TECH IPS power supply!");
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
                    delete(obj.Device);
                    obj.Device = [];
                    obj.IsConnected = false;
                    obj.HasError = false;
                    obj.RelayStatus = [];
                    result = true;
                catch
                    error("Unable to disconnect device: " + obj.Port);
                end
            else
                error("Device is not connected");
            end
        end
        
        function result = Initialize(obj) % Update the object values to match with the current illuminator values
            result = false;
            if (obj.GetStatus())
                obj.HasError = false;
                result = true;
            else
                obj.HasError = true;
            end
        end

        function ReadSerial(obj, source, event) % Processes the returned serial message together with the LatestCommand sent
            try
                message = strtrim(read(source, source.NumBytesAvailable, "char")); % Read returned message, remove CR, LF (\r\n) etc.
                % disp(message);
                % return
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
                return
            end
            obj.LatestMessage = message;
            obj.HasError = false;
            % Find the dictionary key based on receive message and parse the received message of a read value command
            switch obj.LatestCommand
                case obj.D_CMD{"Status"} % Vvv.vvAa.aaaWwww.wUuuIi.iiPpppFffffff where V, A, W = output values and U, I, and P = limit values , F values for status
                    if (length(message) >= 34) % Sometimes a partial string of the 37 char status message is received! A race condition?
                        % disp(message)
                        obj.OutputVoltage = str2double(message(2:6)); % 5 chars
                        obj.OutputCurrent = str2double(message(8:12)); % 5 chars
                        obj.OutputLoad = str2double(message(14:18)); % 5 chars
                        obj.VoltageLimit = str2double(message(20:21)); % 2 chars
                        obj.CurrentLimit = str2double(message(23:26)); % 4 chars
                        obj.LoadLimit = str2double(message(28:30)); % 3 chars
                        if (strcmp(message(32), '1'))
                            obj.RelayStatus = true;
                        else
                            obj.RelayStatus = false;
                        end
                        if (strcmp(message(33), '1'))
                            obj.Temperature = 'Overheat';
                        else
                            obj.Temperature = 'Normal';
                        end
                        if (strcmp(message(34), '1'))
                            obj.Knob = 'Fine';
                        else
                            obj.Knob = 'Normal';
                        end
                    else
                        disp("Not enough letters in message!")
                        disp(message)
                        obj.HasError = true;
                    end
                case obj.D_CMD{"OutputCurrent"}
                    obj.OutputCurrent = str2double(message(2:6));
                case obj.D_CMD{"OutputVoltage"}
                    obj.OutputVoltage = str2double(message(2:6));
                case obj.D_CMD{"OutputLoad"}
                    obj.OutputLoad = str2double(message(2:6));
                case obj.D_CMD{"CurrentLimit"}
                    obj.CurrentLimit = str2double(message(2:5));
                case obj.D_CMD{"VoltageLimit"}
                    obj.VoltageLimit = str2double(message(2:3));
                case obj.D_CMD{"LoadLimit"}
                    obj.LoadLimit = str2double(message(2:4));
                otherwise
                    obj.HasError = true;
                    disp("Error with message:")
                    disp(message)
            end
        end

        function result = Flush(obj) % Add to app GUI to help with debugging
            result = false;
            flush(obj.Device);
            pause(obj.WAIT_TIME);
            result = true;
        end

        function result = Reset(obj) % Add to app GUI to help with debugging
            result = false;
            if (~obj.Disconnect()) % Disconnect gracefully
                delete(obj.Device); % Delete device serialport connection
            end
            pause(obj.WAIT_TIME);
            if (obj.Connect())
                pause(obj.WAIT_TIME);
                if (obj.Initialize())
                    result = true;
                end
            end
        end

        function result = Refresh(obj) % Updating values with app timer, also to update object values with actual pump values (checking set commands were successful)
            result = false;
            if (~isempty(serialportfind(Port=obj.Port)))
                obj.IsConnected = true;
                if (obj.GetStatus())
                    result = true;
                else
                    obj.Flush();
                    obj.HasError = true;
                end
            else
                obj.IsConnected = false;
                delete(obj.Device);
                obj.Device = [];
                error("Lost connection to ISO-TECH IPS power supply at port: " + obj.Port);
            end
        end
        
        function result = SendSerial(obj, cmd) % All sent commands via this function
            result = false;
            flush(obj.Device); % To be sure
            obj.LatestCommand = cmd;
            writeline(obj.Device, cmd);
            pause(obj.WAIT_TIME);
            % All commands that do not return values, and thus the success of setting the value is checked with a follow up status check
            % KOE / KOD = Relay ON / OFF; KO = Toggle relay
            % (1:2): SI, SU, SP = Set the limit to a specific value, SIM / SUM / SPM = Set the limit to a maximum value
            % SV = Set the voltage output value to a specific value
            if (length(obj.LatestCommand) > 1)
                if (strcmp(obj.LatestCommand(1:2), 'SI') || strcmp(obj.LatestCommand(1:2), 'SU') || strcmp(obj.LatestCommand(1:2), 'SP') || strcmp(obj.LatestCommand(1:2), 'KN') || strcmp(obj.LatestCommand(1:2), 'KF'))
                    result = obj.Refresh();
                elseif (strcmp(obj.LatestCommand(1:2), 'KO') || strcmp(obj.LatestCommand(1:2), 'SV')) % Voltage rise time requires a longer wait time
                    pause(obj.WAIT_TIME);
                    result = obj.Refresh();
                end
            else
                result = true;
            end
        end

        function result = On(obj) % Relay/output on
            result = obj.SendSerial(obj.D_CMD{'On'});
        end

        function result = Off(obj) % Relay/output off
            result = obj.SendSerial(obj.D_CMD{'Off'});
        end

        function result = ToggleRelay(obj) % Toggle relay/output status
            result = obj.SendSerial(obj.D_CMD{'ToggleRelay'});
        end

        function result = GetStatus(obj) %
            result = obj.SendSerial(obj.D_CMD{'Status'});
        end

        function result = SetKnobNormal(obj) %
            result = obj.SendSerial(obj.D_CMD{'KnobNormal'});
        end

        function result = SetKnobFine(obj) %
            result = obj.SendSerial(obj.D_CMD{'KnobFine'});
        end

        function result = SetOutputVoltage(obj, val) % If the input val was above the VoltageLimit value, the OutputVoltage value would equal the VoltageLimit value
            assert(isnumeric(val) && val <= obj.VoltageLimit && val >= 0, 'Value must be numeric and between 0 and VoltageLimit!'); % Check anyway
            s = ' ';
            cmd = [obj.D_CMD{'SetValue'}, obj.D_CMD{'OutputVoltage'}, s, num2str(val, '%.2f')]; % SV xx.xx
            result = obj.SendSerial(cmd);
        end
        
        function result = GetOutputVoltage(obj)
            result = obj.SendSerial(obj.D_CMD{'OutputVoltage'});
        end

        function result = GetOutputCurrent(obj)
            result = obj.SendSerial(obj.D_CMD{'OutputCurrent'});
        end

        function result = GetOutputLoad(obj)
            result = obj.SendSerial(obj.D_CMD{'OutputLoad'});
        end

        function result = GetCurrentLimit(obj)
            result = obj.SendSerial(obj.D_CMD{'CurrentLimit'});
        end

        function result = GetVoltageLimit(obj)
            result = obj.SendSerial(obj.D_CMD{'VoltageLimit'});
        end

        function result = GetLoadLimit(obj)
            result = obj.SendSerial(obj.D_CMD{'LoadLimit'});
        end

        function result = SetMaxCurrentLimit(obj)
            cmd = [obj.D_CMD{'SetValue'}, obj.D_CMD{'MaxCurrentLimit'}];
            result = obj.SendSerial(cmd);
        end

        function result = SetMaxVoltageLimit(obj)
            cmd = [obj.D_CMD{'SetValue'}, obj.D_CMD{'MaxVoltageLimit'}];
            result = obj.SendSerial(cmd);
        end

        function result = SetMaxLoadLimit(obj)
            cmd = [obj.D_CMD{'SetValue'}, obj.D_CMD{'MaxLoadLimit'}];
            result = obj.SendSerial(cmd);
        end

        function result = SetCurrentLimit(obj, val) % Also changes LoadLimit!
            assert(isnumeric(val) && val <= obj.MaxCurrent && val >= 0, 'Value must be numeric and between 0 and MaxCurrent!');
            s = ' ';
            cmd = [obj.D_CMD{'SetValue'}, obj.D_CMD{'CurrentLimit'}, s, num2str(val, '%.2f')]; % SI xx.xx
            result = obj.SendSerial(cmd);
        end

        function result = SetVoltageLimit(obj, val) % Also changes LoadLimit!
            assert(isnumeric(val) && val <= obj.MaxVoltage && val >= 0, 'Value must be numeric and between 0 and MaxVoltage!');
            s = ' ';
            cmd = [obj.D_CMD{'SetValue'}, obj.D_CMD{'VoltageLimit'}, s, num2str(val, '%02i')]; % SU xx (NB! Only PSUs with U < 100 V ?)
            result = obj.SendSerial(cmd);
        end

        function result = SetLoadLimit(obj, val) % The power setting changes the current limit only, the voltage limit will remain unchanged
            assert(isnumeric(val) && val <= obj.MaxLoad && val >= 0, 'Value must be numeric and between 0 and MaxLoad!');
            s = ' ';
            cmd = [obj.D_CMD{'SetValue'}, obj.D_CMD{'LoadLimit'}, s, num2str(val, '%03i')]; % SP xxx (NB! Only PSUs with P < 1kW ?)
            result = obj.SendSerial(cmd);
        end

    end

    methods (Static)

        function PortsAvailable = GetAvailableCOMs()
            PortsAvailable = serialportlist("available");
        end

    end

end