% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% MATLAB class for SugarCUBE™ LED Illuminators using RS232/serialport
% Tested models: White with firmware version 01.05.00
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Author(s): Dr. Juha-Pekka Hieta (2025)
% Current version: 03/2025
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Compatibility: MATLAB 2022b or newer (uses 'dictionary')
% RS-232 commands can use upper or lower case characters
% Firmware versions 01.01.00 and newer are supported. For firmware version 01.00.00, all commands except .Brighten() ('^') and .Dim() ('v') are valid
% Functions return boolean false / true for error / success --> Utilize in apps
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% scube = Sugarcube("COM26"); % Initialise SugarCUBE LED illuminator
% scube.Connect(); % Create and open serialport/RS232 connection
% scube.Initialize(); % Set all object values to match with the illuminator values
% scube.Refresh(); % Read and refresh values (e.g., with app timers)
% scube.On(); % Turn on the lamp
% scube.Intensity(30); % Sets illumination intensity to 30%
% scube.Standby(); % Turn off the lamp
% scube.Flush(); % Flush the serialport (minor error)
% scube.Reset(); % Try to reset the serial port connection (major error)
% scube.Disconnect(); % Close the serial port connection
% delete(scube); % Delete the MATLAB object

classdef Sugarcube < handle
   
    properties (Constant, Hidden) % Change if necessary to preconfigure for your device
        BAUD_RATE = 19200; % COM/Serial port settings
        DATA_BITS = 8;
        PARITY = "none";
        STOP_BITS = 1;
        FLOW_CONTROL = "none";
        D_CMD = dictionary(["On", "Standby", "Brighten", "Dim", "Lock", "Unlock", "Status", "Temperature", "Firmware", "SerialNumber"], {'+', '-', '^', 'v', 'lock', 'unlock', 's', 't', '?', '#'}); % All commands translated to English
        D_STATUS = dictionary(["On", "Standby"], {'+', '-'}); % All status messages translated to English
        WAIT_TIME = 0.3; % Wait time in seconds between sent serial commands within class functions
    end

    properties % Changable from app
        IsConnected = false; % Is serial port connection open
        HasError = false; % Error state
        PollingInterval = 30; % Interval between polling events in seconds, use with app timers
        Device; % MATLAB serialport object (all commands are sent to Device)
        Port; % COM port, e.g., "COM10"
        Firmware = []; % Device firmware version
        SerialNumber = []; % Device serial number (use to identify multiple devices?)
        IsLocked = false; % Are the overlay buttons locked? (software control only)
        Temperature = []; % LED temperature [degree Celsius]
        Intensity = 10; % Illumination intensity in percentage units, e.g. 10 = 10% of maximum intensity
        Status = []; % Run status, see D_STATUS above
        LatestCommand; % Latest sent serial command
        LatestMessage; % Latest read serial response
    end

    methods

        function obj = Sugarcube(Port)
            if (nargin == 1)
                obj.Port = string(Port);
            else
                error("Please input one argument only: MATLAB COM port as a string (e.g., COM2)");
            end
        end

        function result = Connect(obj)
            result = false;
            PortsAvailable = obj.GetAvailableCOMs();
            if (~isempty(find(contains(PortsAvailable, obj.Port), 1))) % Check that the COM port is available
                if (~obj.IsConnected)
                    try
                        obj.Device = serialport(obj.Port, obj.BAUD_RATE, DataBits=obj.DATA_BITS, Parity=obj.PARITY, StopBits=obj.STOP_BITS, FlowControl=obj.FLOW_CONTROL);
                        configureTerminator(obj.Device, "CR", "CR");
                        configureCallback(obj.Device, "terminator", @obj.ReadSerial);
                        obj.IsConnected = true;
                        obj.HasError = false;
                        result = true;
                    catch
                        obj.Device = [];
                        obj.IsConnected = false;
                        obj.HasError = true;
                        error("Failed to connect to SugarCUBE LED illuminator!");
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
                    obj.Status = [];
                    result = true;
                catch
                    error("Unable to disconnect device: " + obj.Port);
                end
            else
                error("Device is not connected");
            end
        end
        
        function result = Initialize(obj) % Update all object values to match with the current Sugarcube values
            result = false;
            if (obj.GetStatus())
                pause(obj.WAIT_TIME);
                if (obj.GetSerialNumber())
                    pause(obj.WAIT_TIME);
                    if (obj.GetFirmware())
                        pause(obj.WAIT_TIME);
                        if (obj.GetTemperature())
                            obj.HasError = false;
                            result = true;
                        else
                            obj.HasError = true;
                        end
                    else
                        obj.HasError = true;
                    end
                else
                    obj.HasError = true;
                end
            else
                obj.HasError = true;
            end
        end

        function ReadSerial(obj, source, event) % Processes the returned serial message together with the LatestCommand sent
            try
                message = strtrim(read(source, source.NumBytesAvailable, "char")); % Read returned message, remove CR, LF (\r\n) etc.
                % disp(message);
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
                return
            end
            obj.LatestMessage = message;
            if (strcmp(obj.LatestMessage, "Bad")) % Bad command is received if the intensity value was invalid
                obj.HasError = true;
                flush(obj.Device);
                wait = obj.Refresh(); % Get the correct intensity
                return
            end
            % Find the dictionary key based on receive message and parse the received message of a read value command
            switch obj.LatestCommand
                case obj.D_CMD{"Status"}
                    obj.Intensity = str2double(message(1:3)); % '010', '100'
                    obj.HasError = true; % Will be resetted if a match is found below
                    for j = 1:length(obj.D_STATUS.values) % Match returned char with a dict value for getting running state
                        if (strcmp(obj.D_STATUS.values{j}, message(4)))
                            obj.Status = obj.D_STATUS.keys{j};
                            obj.HasError = false;
                        end
                    end
                    if (strcmp(message(5), 'u')) % Unlocked buttons 
                        obj.IsLocked = false;
                    elseif (strcmp(message(5), 'l')) % Locked overlay buttons
                        obj.IsLocked = true;
                    else
                        obj.HasError = true;
                    end
                case obj.D_CMD{"Firmware"}
                    obj.Firmware = message;
                case obj.D_CMD{"SerialNumber"}
                    obj.SerialNumber = message;
                case obj.D_CMD{"Temperature"}
                    obj.Temperature = str2double(message);
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
                if (obj.GetStatus()) % Does not refresh the LED temperature
                    result = true;
                    % pause(obj.WAIT_TIME);
                    % if (obj.GetTemperature())
                    %     result = true;
                    % else
                    %     obj.Flush();
                    %     obj.HasError = true;
                    % end
                else
                    obj.Flush();
                    obj.HasError = true;
                end
            else
                obj.IsConnected = false;
                delete(obj.Device);
                obj.Device = [];
                error("Lost connection to SugarCUBE LED illuminator at port: " + obj.Port);
            end
        end
        
        function result = SendSerial(obj, cmd) % All sent commands via this function
            result = false;
            flush(obj.Device); % To be sure
            obj.LatestCommand = cmd;
            writeline(obj.Device, cmd);
            pause(obj.WAIT_TIME);
            % All commands that do not return values, and thus the success of setting the value is checked with a follow up status check
            if (strcmp(obj.LatestCommand, '+') || strcmp(obj.LatestCommand, '-') || strcmp(obj.LatestCommand, '^') || strcmp(obj.LatestCommand, 'v') || strcmp(obj.LatestCommand, 'lock') || strcmp(obj.LatestCommand, 'unlock'))
                result = obj.Refresh(); % Only way to update these values is to read them all
            elseif (~isnan(str2double(cmd))) % If the first letter is a valid number, the LED intensity is being set. If it fails, "Bad" is returned and obj.Refresh() will be triggered via ReadSerial()
                obj.Intensity = str2double(cmd);
            else
                result = true;
            end
        end

        function result = On(obj) % Lamp on
            result = obj.SendSerial(obj.D_CMD{'On'});
        end

        function result = Standby(obj) % Lamp off
            result = obj.SendSerial(obj.D_CMD{'Standby'});
        end

        function result = Brighten(obj) % +10 %-points or to the closest ten (30% -> 40%, 45% -> 50%)
            result = obj.SendSerial(obj.D_CMD{'Brighten'});
        end

        function result = Dim(obj) % -10 %-points or to the closest ten (30% -> 20%, 45% -> 40%)
            result = obj.SendSerial(obj.D_CMD{'Dim'});
        end

        function result = SetIntensity(obj, val) % Set LED intensity value as a percentage value [0-100]
            assert(isinteger(val) && val <= 100 && val >= 10, 'Value must be an integer and between 10 and 100!');
            result = obj.SendSerial(string(val));
        end

        function result = GetStatus(obj) % Intensity, LED status, Lock status
            result = obj.SendSerial(obj.D_CMD{'Status'});
        end

        function result = GetTemperature(obj) % LED temperature in degC
            result = obj.SendSerial(obj.D_CMD{'Temperature'});
        end

        function result = GetFirmware(obj) % Firmware version
            result = obj.SendSerial(obj.D_CMD{'Firmware'});
        end

        function result = GetSerialNumber(obj) % Device serial number
            result = obj.SendSerial(obj.D_CMD{'SerialNumber'});
        end       

    end

    methods (Static)

        function PortsAvailable = GetAvailableCOMs()
            PortsAvailable = serialportlist("available");
        end

    end

end