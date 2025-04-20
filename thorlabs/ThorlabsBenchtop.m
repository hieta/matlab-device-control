% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% MATLAB class for Thorlabs BSC benchtop controllers. Uses Thorlabs .NET libraries (Kinesis)
% Tested models: BSC-202 (two-channel benchtop stepper motor controller)
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Author(s): Dr. Juha-Pekka Hieta (2023), Dr. Julan A.J. Fells
% Current version: 08/2024
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Compatibility: MATLAB version not checked!
% Installation of Thorlabs Kinesis software is required, see the LIB_PATH!
% Each ThorlabsBenchtop controller Channel will point to a separate ThorlabsStage object for which there is a separate MATLAB class
% Check the .SetCalibrationFile() function in ThorlabsStage class to include your stage .dat calibration file provided by Thorlabs! (if any)
% Functions return boolean false / true for error / success → Utilize in apps
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% xy = ThorlabsBenchtop(); % Create a Thorlabs benchtop controller
% xy.Connect('70862881'); % Connect to a stage using a deviceID. Benchtop controller class connects to all stages via different Channels. This also sets the calibration file defined in ThorlabsStage!
% x = xy.Channel{1}; % Create a separate handle for the X and Y stages for more convenient access
% y = xy.Channel{2};
% x.SetVelocityParameters(1.0, 0.5); % Set the velocity and accelaration of the X stage
% x.MoveTo(12.5); % Moves the X stage to the coordinate X = 12.5
% x.MoveRelative(10.0); % Moves the X stage to the coordinate X = 22.5 (+10)
% x.Refresh(); % Refresh the stage values
% x.Motor.IsDeviceBusy(); % Use this (true/false) with a MATLAB timer to disable certain GUI features when the device is moving
% xy.Disconnect(); % Disconnect the stages and benchtop controller (NB! xy)
% delete(xy); % Delete the MATLAB controller object

classdef ThorlabsBenchtop < handle

    properties (Constant, Hidden)
        LIB_PATH = "C:\Program Files\Thorlabs\Kinesis\";
        DEVICE_MANAGER_CLI = "Thorlabs.MotionControl.DeviceManagerCLI.dll";
        GENERIC_MOTOR_CLI = "Thorlabs.MotionControl.GenericMotorCLI.dll";
        BENCHTOP_STEPPERMOTOR_CLI = "Thorlabs.MotionControl.Benchtop.StepperMotorCLI.dll";
    end

    properties
        Connected = false;
        Controller = [];
        DeviceID = [];
        ChannelCount = 0;
        Channel = [];
    end

    methods

        function obj = ThorlabsBenchtop()
            ThorlabsBenchtop.LoadLibraries(); % Loads if necessary
        end

        function result = Connect(obj, DeviceID)
            result = false;
            ThorlabsDevicesAvailable = obj.GetDeviceList(); % Get all devices
            if (~obj.Connected && ~isempty(find(contains(ThorlabsDevicesAvailable, DeviceID), 1))) % Check that the device with a DeviceID is available
                try
                    obj.Controller = Thorlabs.MotionControl.Benchtop.StepperMotorCLI.BenchtopStepperMotor.CreateBenchtopStepperMotor(DeviceID);
                catch
                    error("Unable to create a BenchtopStepperMotor device for controller: " + DeviceID);
                end
                pause(2);
                obj.Controller.Connect(DeviceID);
                pause(2); % Something weird is happening here without wait
                if (~obj.Controller.IsConnected())
                    error("Unable to connect the device: " + DeviceID);
                    return
                else
                    obj.Connected = true;
                    obj.DeviceID = DeviceID;
                end
                % Number of channel slots in a controller? (this gives n = 3 for BSC202 although only two controller cards are installed)
                % Each Channel controls a single stage/motor/actuator
                obj.ChannelCount = obj.Controller.ChannelCount;
                if (obj.ChannelCount > 0)
                    for j = 1:obj.ChannelCount
                        if (obj.Controller.IsBayValid(j))
                            obj.Channel{j} = ThorlabsStage(); % Each channel will point to a separate ThorlabsStage object
                            obj.Channel{j}.Motor = obj.Controller.GetChannel(j); % This is equal to ThorlabsStage.Connect()
                            obj.Channel{j}.Motor.WaitForSettingsInitialized(10000); % Wait for settings in the background, note the order vs the motor object
                            obj.Channel{j}.Initialize();
                            obj.Channel{j}.DeviceID = string(obj.Channel{j}.Motor.DeviceID);
                            obj.Channel{j}.SetCalibrationFile(); % .dat files that arrived with your stage
                        end
                    end
                else
                    error("Unable to find any channels on controller: " + DeviceID);
                end
            else
                error("The following controller is not available: " + DeviceID);
            end
            result = true;
        end
        
        function ResetController(obj)
            obj.Controller.ResetConnection(obj.DeviceID)
        end

        function ResetChannels(obj)
            obj.Connected = obj.Controller.IsConnected();
            if (obj.Connected)
                try
                    for j = 1:obj.ChannelCount
                        if (obj.Controller.IsBayValid(j))
                            obj.Channel{j}.Motor.ClearDeviceExceptions();
                            pause(1);
                            obj.Channel{j}.Motor.Reset();
                            pause(1);
                        end
                    end
                catch
                    error("Unable to reset the channel number " + j);
                end
            else
                error("Thorlabs controller is not connected!")
            end
        end

        function result = Disconnect(obj)
            result = false;
            obj.Connected = obj.Controller.IsConnected();
            if (obj.Connected)
                try
                    for j = 1:obj.ChannelCount
                        if (obj.Controller.IsBayValid(j))
                            obj.Channel{j}.Motor.StopPolling();
                            pause(0.5);
                        end
                    end
                    obj.Controller.Disconnect();
                    pause(3);
                    obj.Connected = false;
                    obj.DeviceID = [];
                    obj.ChannelCount = 0;
                    obj.Channel = [];
                    result = true;
                catch
                    error("Unable to disconnect the controller: " + obj.DeviceID);
                end
            else
                error("Thorlabs controller is not connected!")
            end
        end
    end

    methods (Static)

        function ThorlabsDevicesAvailable = GetDeviceList()
            ThorlabsBenchtop.LoadLibraries();
            Thorlabs.MotionControl.DeviceManagerCLI.DeviceManagerCLI.BuildDeviceList();
            raw_serials = Thorlabs.MotionControl.DeviceManagerCLI.DeviceManagerCLI.GetDeviceList();
            ThorlabsDevicesAvailable = string(cell(ToArray(raw_serials)));
        end

        function LoadLibraries()
            try
                NET.addAssembly(ThorlabsBenchtop.LIB_PATH + ThorlabsBenchtop.DEVICE_MANAGER_CLI);
                NET.addAssembly(ThorlabsBenchtop.LIB_PATH + ThorlabsBenchtop.GENERIC_MOTOR_CLI);
                NET.addAssembly(ThorlabsBenchtop.LIB_PATH + ThorlabsBenchtop.BENCHTOP_STEPPERMOTOR_CLI);
            catch
                error("Unable to load .NET assemblies!")
            end
        end

    end

end