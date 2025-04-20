% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% MATLAB class for Thorlabs stages. Uses Thorlabs .NET libraries (Kinesis)
% Tested models: TDC001 (T-Cube DC servo motor controller)
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Author(s): Dr. Juha-Pekka Hieta (2023), Dr. Julan A.J. Fells
% Current version: 08/2024
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Compatibility: MATLAB version not checked!
% Installation of Thorlabs Kinesis software is required, see the LIB_PATH!
% Check the .SetCalibrationFile() function to include your stage .dat calibration file provided by Thorlabs! (if any)
% Functions return boolean false / true for error / success → Utilize in apps
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% z = ThorlabsStage(); % Create a Thorlabs stage object
% z.Connect('83817592'); % Connect to a stage using its serial number (deviceID)
% z.Initialize(); % Initialize all settings and enable the stage
% z.SetCalibrationFile(); % Attaches the .dat calibration data file to the stage based on its deviceID, if it has any (add yours): see the function SetCalibrationFile()!
% z.SetVelocityParameters(1.0, 0.2); % Set the velocity and accelaration for Z stage
% z.MoveTo(5.0); % Moves the Z stage to the coordinate Z = 5.0
% z.MoveRelative(8.0); % Moves the Z stage to the coordinate Z = 13.0 (+8)
% z.Refresh(); % Update stage info
% z.Motor.IsDeviceBusy(); % Use this (true/false) with a MATLAB timer to disable certain GUI features when the device is moving
% z.Disconnect(); % Disconnect the stage
% delete(z); % Delete the MATLAB stage object

classdef ThorlabsStage < handle
   
    properties (Constant, Hidden)
        LIB_PATH = "C:\Program Files\Thorlabs\Kinesis\";
        DEVICE_MANAGER_CLI = "Thorlabs.MotionControl.DeviceManagerCLI.dll";
        GENERIC_MOTOR_CLI = "Thorlabs.MotionControl.GenericMotorCLI.dll";
        TCUBE_DCSERVO_CLI = "Thorlabs.MotionControl.TCube.DCServoCLI.dll"; % DLL for TDC001. Add more DLLs to control different types of stages!
        BENCHTOP_STEPPERMOTOR_CLI = "Thorlabs.MotionControl.Benchtop.StepperMotorCLI.dll";
        POLLING_TIME = 250;
    end
    
    properties
        Connected = false;
        Motor = [];
        DeviceID = [];
        MotorConfiguration = [];
        MotorDeviceSettings = [];
        DeviceInfo = [];
        WaitHandler = [];
        IsHomed = false;
        IsCalibrationActive = false;
        Position = [];
        MinVelocity = [];
        MaxVelocity = [];
        Acceleration = [];
    end

    methods

        function obj = ThorlabsStage()
            ThorlabsStage.LoadLibraries();
        end

        function result = Connect(obj, DeviceID)
            result = false;
            ThorlabsDevicesAvailable = obj.GetDeviceList(); % Get all devices
            if (~obj.Connected && ~isempty(find(contains(ThorlabsDevicesAvailable, DeviceID), 1))) % Check that the device with a DeviceID is available
                try % Create a device based on DeviceID (serial number)
                    switch DeviceID{1}(1:2) % Example first two digits, add your own
                        case '83'
                            obj.Motor = Thorlabs.MotionControl.TCube.DCServoCLI.TCubeDCServo.CreateTCubeDCServo(DeviceID);
                        case '70'
                            error("The entered serial number belongs to a benchtop controller. Use ThorlabsBenchtop class instead for: " + DeviceID);
                        case '90'
                            error("The entered serial number belongs to a benchtop controller. Use ThorlabsBenchtop class instead for: " + DeviceID);
                        otherwise
                            error("The entered serial number does not match with any of the known devices: " + DeviceID);
                    end
                catch
                    error("Failed to create a device for: " + DeviceID);
                end
                % Connect
                try
                    obj.Motor.Connect(DeviceID);
                    j = 0;
                    if (~obj.Motor.IsSettingsInitialized()) % Wait for motor settings
                        obj.Motor.WaitForSettingsInitialized(3000); % Devices waits this number of milliseconds in the background
                        while (~obj.Motor.IsSettingsInitialized() && j < 10) % Loop wait for settings, sometimes this never occurs!
                            pause(0.5);
                            j = j + 1;
                        end
                    end
                    if (j == 10)
                        error("Timeout. Unable to connect device: " + DeviceID);
                        return
                    else
                        obj.Connected = true;
                        obj.DeviceID = DeviceID;
                    end
                catch
                    error("Unable to connect device: " + DeviceID);
                end
            else
                error("The following device is not available: " + DeviceID);
            end
            result = true;
        end

        function result = Initialize(obj)
            result = false;
            try
                obj.Motor.StartPolling(obj.POLLING_TIME);
            catch
                error("Unable to start polling device: " + obj.DeviceID);
            end
            try
                obj.MotorConfiguration = obj.Motor.LoadMotorConfiguration(obj.Motor.DeviceID);
                pause(1);
            catch
                error("Unable to load motor configuration for device: " + obj.DeviceID);
            end
            try
                obj.MotorDeviceSettings = obj.Motor.MotorDeviceSettings;
            catch
                error("Unable to get motor settings for device: " + obj.DeviceID);
            end
            try
                obj.DeviceInfo = obj.Motor.GetDeviceInfo();
            catch
                error("Unable to get device info for device: " + obj.DeviceID);
            end
            try
                obj.Motor.EnableDevice(); % Enabled the device or no movement is allowed!
            catch
                error("Unable to get device info for device: " + obj.DeviceID);
            end
            try
                obj.WaitHandler = obj.Motor.InitializeWaitHandler(); % Create a wait handler that prevents the program freezing during movement
            catch
                error("Unable to initialize wait handler for device: " + obj.DeviceID);
            end
            obj.Refresh(); % Get data, Refresh(obj);
            result = true;
        end
        
        function result = SetCalibrationFile(obj) % Load calibration data from .dat files
            result = false;
            try
                switch obj.DeviceID % Match calibration data with the DeviceID
                    case "70862881-1"
                        obj.Motor.SetCalibrationFile("436503.dat", true);
                        obj.Motor.MotorDeviceSettings.Calibration.Enabled = true;
                        obj.IsCalibrationActive = obj.Motor.IsCalibrationActive();
                    case "70862881-2"
                        obj.Motor.SetCalibrationFile("436742.dat", true);
                        obj.Motor.MotorDeviceSettings.Calibration.Enabled = true;
                        obj.IsCalibrationActive = obj.Motor.IsCalibrationActive();
                    otherwise
                        error("Motor calibration file not found for device: " + obj.DeviceID)
                end
            catch
                error("Unable to load motor calibration file for device: " + obj.DeviceID);
            end
            result = true;
        end

        function result = Disconnect(obj)
            result = false;
            obj.Connected = obj.Motor.IsConnected();
            if (obj.Connected)
                try
                    obj.Motor.StopPolling();
                    obj.Motor.Disconnect();
                    obj.Connected = false;
                    obj.DeviceID = [];
                    obj.MotorConfiguration = [];
                    obj.MotorDeviceSettings = [];
                    obj.DeviceInfo = [];
                    obj.WaitHandler = [];
                    obj.Position = [];
                    obj.MinVelocity = [];
                    obj.MaxVelocity = [];
                    obj.Acceleration = [];
                    result = true;
                catch
                    error("Unable to disconnect device: " + obj.DeviceID);
                end
            else
                error("Device is not connected")
            end
        end

        function result = ResetConnection(obj)
            result = false;
            obj.Motor.ClearDeviceExceptions();
            pause(1);
            obj.Motor.ResetConnection(obj.DeviceID);
            result = false;
        end

        function Home(obj)
            if (~obj.Motor.IsDeviceBusy())
                obj.Motor.Home(obj.WaitHandler);
                % Use IsDeviceBusy/GetStatusBits in App
                % Refresh() updates IsHomed. Use timer in App for polling.
            else
                error("Device is busy")
            end
        end

        function MoveTo(obj, position)
            if (~obj.Motor.IsDeviceBusy())
                try
                    obj.Motor.MoveTo(position, obj.WaitHandler);
                    % Use IsDeviceBusy/GetStatusBits in the App
                catch
                    error("Unable to move device " + obj.DeviceID + " to " + num2str(position));
                end
            else
                error("Device is busy")
            end
        end

        function MoveRelative(obj, position)
            if (~obj.Motor.IsDeviceBusy())
                try
                    obj.Motor.SetMoveRelativeDistance(position);
                    obj.Motor.MoveRelative(obj.WaitHandler);
                    % Use IsDeviceBusy/GetStatusBits in App
                catch
                    error("Unable to move device " + obj.DeviceID + " to " + num2str(position));
                end
            else
                error("Device is busy")
            end
        end

        function StopImmediate(obj)
            obj.Motor.StopImmediate();
            pause(0.2);
            obj.Refresh();
        end

        function result = SetVelocityParameters(obj, vel, acc)
            result = false;
            try
                velpars = obj.Motor.GetVelocityParams();
                velpars.MaxVelocity = vel;
                velpars.Acceleration = acc;
                obj.Motor.SetVelocityParams(velpars);
            catch
                error("Unable to SetVelocityParameters for device: " + obj.DeviceID);
            end
            obj.Refresh();
            result = true;
        end

        function hex = GetStatusBits(obj)
            try
                hex = dec2hex(obj.Motor.GetStatusBits(), 8);
            catch
                error("Unable to get the status of device: " + obj.DeviceID);
            end
        end

        function result = Refresh(obj)
            result = false;
            obj.Connected = boolean(obj.Motor.IsConnected());
            vel_params = obj.Motor.GetVelocityParams();
            obj.Acceleration = System.Decimal.ToDouble(vel_params.Acceleration);
            obj.MaxVelocity = System.Decimal.ToDouble(vel_params.MaxVelocity);
            obj.MinVelocity = System.Decimal.ToDouble(vel_params.MinVelocity);
            obj.Position = System.Decimal.ToDouble(obj.Motor.Position);
            obj.IsHomed = obj.Motor.Status.IsHomed;
            obj.IsCalibrationActive = obj.Motor.IsCalibrationActive();
            result = true;
        end

    end

    methods (Static)

        function ThorlabsDevicesAvailable = GetDeviceList()
            ThorlabsStage.LoadLibraries();
            Thorlabs.MotionControl.DeviceManagerCLI.DeviceManagerCLI.BuildDeviceList();
            raw_serials = Thorlabs.MotionControl.DeviceManagerCLI.DeviceManagerCLI.GetDeviceList();
            ThorlabsDevicesAvailable = string(cell(ToArray(raw_serials)));
        end

        function LoadLibraries()
            try
                NET.addAssembly(ThorlabsStage.LIB_PATH + ThorlabsStage.DEVICE_MANAGER_CLI);
                NET.addAssembly(ThorlabsStage.LIB_PATH + ThorlabsStage.GENERIC_MOTOR_CLI);
                NET.addAssembly(ThorlabsStage.LIB_PATH + ThorlabsStage.TCUBE_DCSERVO_CLI);
                NET.addAssembly(ThorlabsStage.LIB_PATH + ThorlabsStage.BENCHTOP_STEPPERMOTOR_CLI);
            catch
                error("Unable to load .NET assemblies");
            end    
        end

    end

end