% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% MATLAB class for Harvard Apparatus's syringe pumps using RS232/serialport connection
% Tested models: Pump 11 Elite Infusion Only (70-4500)
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Author(s): Dr. Juha-Pekka Hieta (2025)
% Current version: 03/2025
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Compatibility: MATLAB 2022b or newer (uses 'dictionary')
% Created for a syringe pump that can only infuse samples (no withdraw), add all withdraw features to the class and commands from the manual if necessary.
% Functions return boolean false / true for error / success --> Utilize in apps
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% hap = HarvardApparatus("COM10"); % Initialise Harvard Appratus syringe pump with its COM port
% hap.Connect(); % Create and open serialport/RS232 connection
% hap.Initialize(); % Set all object values to match with the pump values
% hap.SetDiameter(4.608); % Set syringe diameter in millimeters
% hap.SetForceLevel(int8(40)); % Set the pumping force level in percentage units with an integer (!), see the manual for a suggested level for each syringe 
% hap.SetInfusionRate(0.4); % Set the infusion flow rate to 0.4 µL (see Units{2})
% hap.SetTargetVolume(1000); % Set the target volume to 1000 µL (see Units{1})
% hap.Infuse(); % Start infusing
% hap.Refresh(); % Read and refresh values (e.g., with app timers)
% hap.Stop(); % Stop pumping
% hap.Flush(); % Flush the serialport (minor error)
% hap.Reset(); % Try to reset the connection (major error)
% hap.Disconnect(); % Close the serialport connection
% delete(hap); % Delete the MATLAB object

classdef HarvardApparatus < handle
   
    properties (Constant, Hidden) % Change if necessary to preconfigure for your device
        BAUD_RATE = 9600; % COM/Serial port settings
        DATA_BITS = 8;
        PARITY = "none";
        STOP_BITS = 1;
        FLOW_CONTROL = "none";
        D_CMD = dictionary(["Status", "Infuse", "Withdraw", "Stop", "TargetVolume", "InfusionRate", "InfusedVolume", "InfusedTime", "ResetInfusedVolume", "WithdrawRate", "WithdrawnVolume", "WithdrawnTime", "ResetWithdrawnVolume", "Diameter", "ForceLevel", "Address"], {'status', 'run', 'wrun', 'stop', 'tvolume', 'irate', 'itime', 'ivolume', 'civolume', 'wrate', 'wvolume', 'wtime', 'cwvolume', 'diameter', 'force', 'address'}); % All commands translated to English
        D_STATUS = dictionary(["Running", "Stopped", "Target reached", "Stalled"], {'>', ':', 'T*', '*'}); % All status messages translated to English
        WAIT_TIME = 0.3; % Wait time in seconds between sent serial commands within class functions
    end

    properties % Changable from app
        IsConnected = false; % Is serial port connection open
        HasError = false; % Error state
        Address = 0; % Address of the syringe pump [0-99]. Pumps with an address of 0 are masters, and pumps with an address between 1 and 99 are slaves.
        PollingInterval = 30; % Interval between polling events in seconds, use with app timers
        Device; % MATLAB serialport object (all commands are sent to Device)
        Port; % COM port, e.g., "COM10"
        Diameter = 4.608; % Default syringe diameter in millimeters. Check the pdf manual's appendices (page 58) for the diameters of common syringes such as SGE or Hamilton.
        ForceLevel = 40; % Default pumping force level in percentage units. Check the pdf manual for for a suggested level for each syringe
        TargetVolume = 1000.0; % Default target volume without its unit (see Units)
        InfusedVolume = 0.0; % Infused volume without its unit (see Units)
        InfusionRate = 0.4; % Infusion flow rate without its unit (see Units)
        WithdrawnVolume = 0.0; % Withdrawn volume without its unit (see Units), withdraw features not implemented properly!
        WithdrawRate = 0.0; % Withdraw flow rate without its unit (see Units), withdraw features not implemented properly!
        Units = {'ul', 'ul/min'}; % Default units to use for volume and flow rate
        ETA = 'Inf'; % Estimated time for reaching the target volume
        Status = []; % Run status, see D_STATUS above
        LatestCommand; % Latest sent serial command
        LatestMessage; % Latest read serial response
    end

    methods

        function obj = HarvardApparatus(Port)
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
                        error("Failed to connect to Harvard Apparatus syringe pump!");
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
                    obj.ETA = 'Inf';
                    obj.Status = [];
                    result = true;
                catch
                    error("Unable to disconnect device: " + obj.Port);
                end
            else
                error("Device is not connected");
            end
        end
        
        function result = Initialize(obj) % Update the object values to match with the current pump values (app can set its value to the pump afterwards)
            result = false;
            if (obj.GetAddress()) % Get pump Address (master/slave)
                pause(obj.WAIT_TIME);
                if (obj.GetDiameter()) % Get syringe Diameter
                    pause(obj.WAIT_TIME);
                    if (obj.GetForceLevel()) % Get pumping ForceLevel %
                        pause(obj.WAIT_TIME);
                        if (obj.Refresh()) % Get IsConnected, TargetVolume, InfusionRate, InfusedVolume, Status, ETA, Diameter
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
                message = strtrim(read(source, source.NumBytesAvailable, "char")); % Read returned message, remove CR/LF (\r\n)
                message = strsplit(message); % Get a cell array of returned values, use array indeces and LatestCommand to update values etc.
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
                return
            end
            obj.LatestMessage = message;
            % Set commands that return values back (see SendSerial() for set commands that do not return values)
            if (contains(obj.LatestCommand, 'address') && length(obj.LatestMessage) == 6)
                obj.Address = str2double(message{5});
                obj.HasError = false;
                return
            end
            % Read commands always return a value of interest
            % Find the dictionary key based on receive message and parse the received message of a read value command
            switch obj.LatestCommand
                case obj.D_CMD{"Status"} % Sometimes returns the values without running status (missing 5th value, see below if statement)
                    obj.InfusionRate = str2double(message{1}) / 1E9 * 60;
                    obj.InfusedVolume = str2double(message{3}) / 1E9;
                    if (length(message) == 5)
                        for j = 1:length(obj.D_STATUS.values) % Match returned char with a dict value for getting running state
                            if (strcmp(obj.D_STATUS.values{j}, message{5}))
                                obj.Status = obj.D_STATUS.keys{j};
                                obj.HasError = false;
                            end
                        end
                    else
                        obj.HasError = true;
                    end
                    obj.HasError = false;
                case obj.D_CMD{"TargetVolume"}
                    obj.TargetVolume = str2double(message{1});
                    obj.HasError = false;
                case obj.D_CMD{"InfusionRate"}
                    obj.InfusionRate = str2double(message{1});
                    obj.Units{2} = message{2};
                    obj.HasError = false;
                case obj.D_CMD{"InfusedVolume"}
                    obj.InfusedVolume = str2double(message{1});
                    obj.HasError = false;
                case obj.D_CMD{"Diameter"}
                    obj.Diameter = str2double(message{1});
                    obj.HasError = false;
                case obj.D_CMD{"ForceLevel"}
                    obj.ForceLevel = str2double(message{1}(1:end-1)); % Remove the last char (%)
                    obj.HasError = false;
                case obj.D_CMD{"Address"}
                    obj.Address = str2double(message{4});
                    obj.HasError = false;
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
                    pause(obj.WAIT_TIME);
                    if (obj.Refresh())
                        result = true;
                    end
                end
            end
        end

        function result = Refresh(obj) % Updating values with app timer, also to update object values with actual pump values (checking set commands were successful)
            result = false;
            if (~isempty(serialportfind(Port=obj.Port)))
                obj.IsConnected = true;
                if (~obj.GetTargetVolume())
                    obj.HasError = true;
                end
                pause(obj.WAIT_TIME);
                if (~obj.GetStatus())
                    obj.HasError = true;
                end
                pause(obj.WAIT_TIME);
                if (~obj.GetETA())
                    obj.HasError = true;
                end
                result = true;
            else
                obj.IsConnected = false;
                delete(obj.Device);
                obj.Device = [];
                error("Lost connection to Harvard Apparatus syringe pump at port: " + obj.Port);
            end
        end
        
        function result = SendSerial(obj, cmd) % All sent commands via this function
            result = false;
            flush(obj.Device); % To be sure
            obj.LatestCommand = cmd;
            writeline(obj.Device, cmd);
            pause(obj.WAIT_TIME);
            if (strcmp(obj.LatestCommand, 'stop') || strcmp(obj.LatestCommand, 'run') || strcmp(obj.LatestCommand, 'wrun') || strcmp(obj.LatestCommand, 'civolume'))
                result = obj.GetStatus(); % Sending follow up commands removes the returned not-needed chars from the above commands
            elseif (length(obj.LatestCommand) >= 6 && strcmp(obj.LatestCommand(1:5), 'force'))
                result = obj.GetForceLevel(); % Updates the new/current value to make sure the command worked ok
            elseif (length(obj.LatestCommand) >= 9)
                mem_command = obj.LatestCommand; % Remember the current values in the case of setting a new syringe diameter
                mem_rate = obj.InfusionRate;
                mem_target = obj.TargetVolume;
                if (strcmp(obj.LatestCommand(1:7), 'tvolume') || strcmp(obj.LatestCommand(1:8), 'diameter') || strcmp(obj.LatestCommand(1:5), 'irate'))
                    result = obj.GetStatus();
                    pause(obj.WAIT_TIME);
                    result = obj.GetTargetVolume();
                end
                if (strcmp(mem_command(1:8), 'diameter')) % Setting of diameter resets all set pump values (zeros/unset): set the original values back!
                    result = obj.GetDiameter(); % Updates the new/current value to make sure the command worked ok
                    pause(obj.WAIT_TIME);
                    result = obj.SetInfusionRate(mem_rate);
                    pause(obj.WAIT_TIME);
                    result = obj.SetTargetVolume(mem_target);
                end
            else
                result = true;
            end
        end

        function result = Infuse(obj)
            result = obj.SendSerial(obj.D_CMD{'Infuse'});
        end

        function result = Withdraw(obj) % Not implemented otherwise, check pump specs for this capability!
            result = obj.SendSerial(obj.D_CMD{'Withdraw'});
        end

        function result = Stop(obj)
            result = obj.SendSerial(obj.D_CMD{'Stop'});
        end

        function result = GetStatus(obj)
            result = obj.SendSerial(obj.D_CMD{'Status'});
        end

        function result = GetAddress(obj)
            result = obj.SendSerial(obj.D_CMD{'Address'});
        end

        function result = SetAddress(obj, val)
            assert(isnumeric(val), 'Value must be numeric!');
            s = ' ';
            cmd = [obj.D_CMD{'Address'}, s, num2str(val)];
            result = obj.SendSerial(cmd); % Also updates the Address value
        end

        function result = GetETA(obj) % Did not find an inbuilt function for returning this value, calc. approx. value:
            result = false;
            if (strcmp(obj.Status, 'Target reached')) % The calculated value can be negative after reaching the target volume
                obj.ETA = obj.Status;
                result = true;
                return
            end
            volume_remaining = obj.TargetVolume - obj.InfusedVolume; % This function is called from the Refresh function that updates these values in advance
            time_remaining = volume_remaining / obj.InfusionRate; % Assumes same vol units: uL / uL/min ==> min
            time_remaining_minutes = floor(time_remaining);
            time_remaining_seconds = int32((time_remaining - time_remaining_minutes) * 60);
            if (time_remaining_minutes > 60) % Hours:minutes:seconds
                time_remaining_hours = floor(time_remaining_minutes/60);
                time_remaining_minutes = int32((time_remaining_minutes/60 - time_remaining_hours) * 60);
                obj.ETA = strcat(num2str(time_remaining_hours,'%02i'), ':', num2str(time_remaining_minutes,'%02i'), ':', num2str(time_remaining_seconds,'%02i'));
            else % Minutes:seconds
                obj.ETA = strcat(num2str(time_remaining_minutes,'%02i'), ':', num2str(time_remaining_seconds,'%02i'));
            end
            result = true;
        end

        function result = GetTargetVolume(obj)
            result = obj.SendSerial(obj.D_CMD{'TargetVolume'});
        end

        function result = SetTargetVolume(obj, val)
            assert(isnumeric(val), 'Value must be numeric!');
            s = ' ';
            cmd = [obj.D_CMD{'TargetVolume'}, s, num2str(val), s, obj.Units{1}];
            result = obj.SendSerial(cmd); % Also updates the TargetVolume value
        end

        function result = GetInfusedVolume(obj)
            result = obj.SendSerial(obj.D_CMD{'InfusedVolume'});
        end

        function result = ResetInfusedVolume(obj)
            result = obj.SendSerial(obj.D_CMD{'ResetInfusedVolume'});
        end

        function result = GetInfusionRate(obj)
            result = obj.SendSerial(obj.D_CMD{'InfusionRate'});
        end

        function result = SetInfusionRate(obj, val)
            assert(isnumeric(val), 'Value must be numeric!');
            s = ' ';
            cmd = [obj.D_CMD{'InfusionRate'}, s, num2str(val), s, obj.Units{2}];
            result = obj.SendSerial(cmd); % Also updates the InfusionRate value
        end

        function result = GetDiameter(obj)
            result = obj.SendSerial(obj.D_CMD{'Diameter'});
        end

        function result = SetDiameter(obj, val) % Seems to delete other values
            assert(isnumeric(val), 'Value must be numeric!');
            s = ' ';
            cmd = [obj.D_CMD{'Diameter'}, s, num2str(val)];
            result = obj.SendSerial(cmd); % Also updates the Diameter value
        end

        function result = GetForceLevel(obj)
            result = obj.SendSerial(obj.D_CMD{'ForceLevel'});
        end

        function result = SetForceLevel(obj, val) % If infusing/withdrawing, the pumping must be "restarted" before the new level will be used
            assert(isinteger(val) && val <= 100 && val >= 0, 'Value must be an integer and between 0 and 100!');
            s = ' ';
            cmd = [obj.D_CMD{'ForceLevel'}, s, num2str(val)];
            result = obj.SendSerial(cmd); % Also updates the ForceLevel value
        end

    end

    methods (Static)

        function PortsAvailable = GetAvailableCOMs()
            PortsAvailable = serialportlist("available");
        end

    end

end