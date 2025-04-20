% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% MATLAB class for Coherent Sapphire FP series lasers
% Tested models: 548-300 FPT FT
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Author(s): Dr. Juha-Pekka Hieta (2024)
% Current version: 10/2024
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Compatibility: MATLAB 2019b or newer (uses 'serialport')
% Laser PCB DIP switch states: [1 = ON; 2 = ON; 3 = ON; 4 = OFF]
% Does not check for interlocks! See the manual for all available commands and error codes
% Functions return boolean false or true for error or success → Utilize in apps
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% sap = SapphireLaser("COM27"); % Initialize the Coherent Sapphire laser with its COM port
% sap.Connect(); % Create and open serialport/RS232 connection
% sap.Initialize(); % Disables prompt and echo
% sap.Refresh(); % Read and refresh values (e.g., with app timers)
% sap.SetServoState(1); % Enable the servo → beam
% sap.SetPower(100); % Set the laser power, see [MIN_LASER_POWER - MAX_LASER_POWER]
% sap.SetServoState(0); % Disable the servo → no output
% sap.Disconnect(); % Close the serial port connection
% delete(sap); % Delete the MATLAB object

classdef SapphireLaser < handle
   
    properties (Constant, Hidden) % Change if necessary
        BAUD_RATE = 19200; % COM/Serial port settings
        DATA_BITS = 8;
        PARITY = "none";
        STOP_BITS = 1;
        FLOW_CONTROL = "none";
        MIN_LASER_POWER = 10; % Min output power in milliWatts
        MAX_LASER_POWER = 330; % Max output power in milliWatts
        WAIT_TIME = 0.2; % Wait time in seconds between sent serial commands
        POLLING_INTERVAL = 10; % Wait time in seconds to use in app, not utilised here at the moment
    end
    
    properties
        Connected = false; % Serial port connection open/closed (true/false)
        Device; % MATLAB serialport object (all commands are sent to Device)
        Port; % COM port, e.g., "COM5"
        Status; % 1 = Start up, 2 = Warmup, 3 = Standby, 4 = Laser on, 5 = Laser ready
        Faults; % 0 = Fault-free when in standby, 8192 = Fault-free when laser running (on),  256 = Laser is warming up, Other codes = See manual
        ServoState = false; % True = 1 = on (running), False = 0 = off (standby)
        Power; % Read power from the board [mW], should be in the range of MIN_LASER_POWER - MAX_LASER_POWER
    end

    methods

        function obj = SapphireLaser(Port)
            if (nargin == 1)
                obj.Port = Port;
            else
                error("Wrong number of arguments! Please input only the MATLAB COM port as a string, e.g., COM2");
            end
        end

        function success = Connect(obj)
            success = -1;
            PortsAvailable = obj.GetAvailableCOMs();
            % CHECK THAT THE DEVICE IS DISCONNECTED AND THE SERIAL IS AVAILABLE
            if (~isempty(find(contains(PortsAvailable, obj.Port), 1)))
                if (~obj.Connected)
                    try
                        obj.Device = serialport(obj.Port, obj.BAUD_RATE, DataBits=obj.DATA_BITS, Parity=obj.PARITY, StopBits=obj.STOP_BITS, FlowControl=obj.FLOW_CONTROL);
                        obj.Connected = true;
                        success = 1;
                    catch
                        obj.Device = false;
                        obj.Connected = false;
                        obj.Port = [];
                        error("Failed to connect to the UV laser");
                    end
                else
                    error("The following device is already connected: " + obj.Port);
                end
            else
                error("The following device is not available: " + obj.Port);
            end
        end

        function success = Initialize(obj)
            % Initialization makes sure that the laser now returns only numerical values (and \R)
            success = -1;
            obj.Device.writeline(">=0"); % Turns off the laser prompt name (e.g., Sapphire:0->)
            pause(obj.WAIT_TIME);
            obj.Device.writeline("E=0"); % Turns off the command echo (e.g., "?STA")
            pause(obj.WAIT_TIME);
            success = 1;
        end

        function success = Disconnect(obj)
            success = -1;
            if (obj.Connected)
                % Get status and set to standby if necessary
                obj.Status = obj.GetStatus();
                if (obj.Status == 5) % 5 = Laser beam on
                    obj.SetServoState(0) % Turn beam off (L=0)
                    pause(obj.WAIT_TIME);
                    obj.Status = obj.GetStatus();
                    if (obj.Status ~= 3) % Standby
                        error("DANGER! Unable to turn off the laser output, WATCH OUT!");
                    end
                end
                % Delete object
                try
                    delete(obj.Device);
                    obj.Device = [];
                    obj.Connected = false;
                    obj.Port = [];
                    obj.Status = [];
                    obj.Faults = [];
                    obj.ServoState = [];
                    obj.Power = [];
                catch
                    error("Unable to disconnect device: " + obj.Port);
                end
            else
                error("Device is not connected");
            end
            success = 1;
        end
       
        function status = Refresh(obj)
            % Update COM port connection status and delete 
            if (~isempty(serialportfind(Port=obj.Port)))
                obj.Connected = true;
                status = 1;
            else
                status = -1;
                obj.Connected = false;
                delete(obj.Device);
                obj.Device = [];
                obj.Port = [];
                obj.Status = [];
                obj.ServoState = [];
                obj.Power = [];
                error("Lost connection to Coherent Sapphire laser at port: " + obj.Port);
            end
            obj.ServoState = obj.GetServoState(); % Update laser light servo state
            obj.Status = obj.GetStatus(); % Update status
            obj.Power = obj.GetPower(); % Update laser power
            obj.Faults = obj.GetFaults(); % Update faults
        end

        function status = GetServoState(obj)
            status = -1;
            obj.Device.writeline("?L"); % L = 1 = on, L = 0 = off
            pause(obj.WAIT_TIME);
            status = int32(obj.ReadReturn());
            flush(obj.Device);
        end

        function SetServoState(obj, new_state)
            obj.Device.writeline("L=" + num2str(int32(new_state))); % State = 1 = on, 0 = off
            pause(obj.WAIT_TIME);
            flush(obj.Device);
        end

        function SetPower(obj, new_power)
            % Check power value
            if (new_power <= obj.MAX_LASER_POWER && new_power >= obj.MIN_LASER_POWER)
                obj.Device.writeline("P=" + num2str(int32(new_power))); % Do not accept float
                pause(obj.WAIT_TIME);
                flush(obj.Device);
            else
                error("Set power value is out of range!");
            end
        end

        function power = GetPower(obj)
            %  Light Servo MUST be enabled (L=1)
            if (obj.ServoState)
                obj.Device.writeline("?P"); % P = Real power
                pause(obj.WAIT_TIME);
                power = obj.ReadReturn();
                flush(obj.Device);
            else
                power = 0;
            end
        end

        function power = GetSetPower(obj)
            power = -1;
            obj.Device.writeline("?SP"); % SP = Set power
            pause(obj.WAIT_TIME);
            power = obj.ReadReturn();
            flush(obj.Device);
        end

        function status = GetStatus(obj)
            status = -1;
            obj.Device.writeline("?STA");  % 1 = Start up, 2 = Warmup, 3 = Standby, 4 = Laser on, 5 = Laser ready
            pause(obj.WAIT_TIME);
            status = obj.ReadReturn();
            flush(obj.Device);
        end

        function faults = GetFaults(obj)
            faults = -1;
            obj.Device.writeline("?FF");
            pause(obj.WAIT_TIME);
            faults = obj.ReadReturn(); % 0 = fault-free when in standby, 8192=fault-free when laser on,  256 = laser is starting up after power on
            flush(obj.Device);
        end

        function val = ReadReturn(obj)
            if (obj.Device.NumBytesAvailable > 0)
                read_string = read(obj.Device, obj.Device.NumBytesAvailable, "char");
                val = str2double(strtrim(read_string)); % Removes the return carriages surrounding the numeric value
            else
                val = -1;
            end
        end

    end

    methods (Static)

        function PortsAvailable = GetAvailableCOMs()
            PortsAvailable = serialportlist("available");
        end

    end

end