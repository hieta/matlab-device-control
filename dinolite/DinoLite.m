% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% MATLAB class for Dino-Lite Digital Microscopes
% Tested models: Edge AM7115, Edge AM7915
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Author(s): Dr. Juha-Pekka Hieta (2023)
% Current version: 11/2024
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% Compatibility: MATLAB version not checked!
% LED control requires Dino-Lite DOS Control (DN_DS_Ctrl.exe), see and modify the EXE_PATH below
% DeviceID (cam index) is currently based on the order cameras were attached to the PC
% Use the device name instead of DeviceID number if the camera names are unique. For example, two 'Edge' series cameras had equal device names and thus they could not be used as unique identifiers
% Functions return boolean false / true for error / success → Utilize in apps
% -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
% dino = DinoLite(); % Initialise a Dino-Lite digital microscope
% dino.Connect(1); % Connect to a Dino-Lite microscope with a DeviceID = 1 and apply the predetermined settings for the camera (see .Connect())
% app.dino.SetROI([0 142 1600 916]); % Crop 1600x1200 feed to 1600x916 [X Y Width Height]
% app.dino.Source.Brightness = Some_Brightness_Slider.Value; % Set camera settings to match with some app slider values (or other way around)
% app.dino.Source.Contrast = ...
% app.dino.Source.Gamma = ...
% app.dino.Source.Sharpness = ...
% dino.ToggleLEDs()); % Sets all individual LED states to false or true regardless of their individual states
% dino.LED1 = true; % Set LED1 state to ON
% dino.SetLEDs()); % Update the camera LED states as set above
% dino.SetLEDBrightness(3); % Set the LEDs brightness to level 3
% delete(dino); % Delete/disconnect

classdef DinoLite < handle
   
    properties (Constant, Hidden)
        %EXE_PATH = '"C:\Program Files (x86)\Dino-Lite DOS Control\DN_DS_Ctrl.exe"'; % Use the install directory
        EXE_PATH = "DinoliteLEDCtrl.exe"; % Renamed and moved the .exe to some folder that was added to MATLAB path
    end
    
    properties
        Connected = false;
        DeviceID; % A running device index number
        VideoInput; % As in MATLAB
        Source; % As in MATLAB
        LedControl = false; % Can the LEDs be set, see the EXE_PATH and .CheckTool() function
        LEDs = false; % Are LEDs enabled
        LED1 = false; % State of a single LED
        LED2 = false;
        LED3 = false;
        LED4 = false;
        Brightness = 6; % Levels 1-6, 0 = LEDs are disabled
    end

    methods

        function obj = DinoLite()
            if (DinoLite.CheckTool())
                obj.LedControl = true;
            end
        end

        function result = Connect(obj, DeviceID)
            result = false;
            assert(isnumeric(DeviceID), "Please input the camera index number as an integer!");
            try
                switch DeviceID % Settings for different cameras based on their index number. INDEX IS BASED ON THE ORDER WHICH CAMERAS WERE ATTACHED TO THE PC! Use device names instead if they are unique!
                    case 1 % Camera with ID = 1 settings
                        obj.VideoInput = videoinput("winvideo", 1, "MJPG_1600x1200"); % Check the available indeces and formats in MATLAB: info = imaqhwinfo('winvideo'); --> info.DeviceIDs and info.DeviceInfo.SupportedFormats
                        obj.VideoInput.ReturnedColorspace = "rgb";
                        obj.VideoInput.LoggingMode = "disk&memory";
                        obj.VideoInput.PreviewFullBitDepth = "on";
                    case 2 % Camera with ID = 2 settings
                        obj.VideoInput = videoinput("winvideo", 2, "MJPG_1600x1200");
                        obj.VideoInput.ReturnedColorspace = "rgb";
                        obj.VideoInput.LoggingMode = "disk&memory";
                        obj.VideoInput.PreviewFullBitDepth = "on";
                    otherwise % Error
                        error("Invalid camera index!")
                end
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
                error("Unable to connect Dino-Lite USB camera device number " + num2str(DeviceID));
            end
            obj.Source = getselectedsource(obj.VideoInput); % Set Source.Brightness, .Contrast, etc. values from the app GUI with sliders etc.
            obj.DeviceID = DeviceID;
            obj.Connected = true;
            if (obj.LedControl) % All LEDs are lit when connected (cannot be changed, Dino-Lite's design)
                obj.LEDs = true;
                obj.LED1 = true;
                obj.LED2 = true;
                obj.LED3 = true;
                obj.LED4 = true;
            end
            result = true;
        end

        function result = SetROI(obj, ROI)
            result = false;
            try
                obj.VideoInput.ROIPosition = ROI;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
                error("Unable to set ROI for video feed of Dino-Lite camera number: " + num2str(obj.DeviceID) + ". ROI must be in format [X Y Width Height].");
            end
            result = true;
        end

        function result = ToggleLEDs(obj) % Enabled or disable LEDs (also resets individual LED states)
            result = false;
            if (~obj.LedControl)
                error("Unable to toggle LEDs! Dino-Lite DOS Control installation does not exist!");
            end
            try
                switch obj.LEDs
                    case true
                        dos(obj.EXE_PATH + " LED off 1 -CAM" + num2str(obj.DeviceID)); % Example: DN_DS_Ctrl.exe LED off 1 -CAM1
                        obj.LEDs = false;
                        obj.LED1 = false;
                        obj.LED2 = false;
                        obj.LED3 = false;
                        obj.LED4 = false;
                        obj.Brightness = 0;
                    case false
                        dos(obj.EXE_PATH + " LED on 1 -CAM" + num2str(obj.DeviceID)); % Example: DN_DS_Ctrl.exe LED on 1 -CAM1
                        obj.LEDs = true;
                        obj.LED1 = true;
                        obj.LED2 = true;
                        obj.LED3 = true;
                        obj.LED4 = true;
                        if (obj.SetLEDBrightness(6)) % Ensure that all LEDs are enabled and the brightness is set to max when enabling LEDs (app GUI) 
                            obj.Brightness = 6;
                        end
                        obj.SetLEDs();
                end
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
                error("Failed to toggle Dino-Lite LEDs of device " + num2str(obj.DeviceID));
            end
            result = true;
        end
        
        function result = SetLEDs(obj) % Toggle a set of LEDs
            result = false;
            assert(obj.LedControl, "Unable to switch LED states. Dino-Lite DOS Control installation does not exist.");
            assert(obj.LEDs, "Unable to switch LED states. LEDs are disabled.");
            try
                dos(obj.EXE_PATH + " FLCSwitch " + num2str(obj.LED1) + num2str(obj.LED2) + num2str(obj.LED3) + num2str(obj.LED4) + " -CAM" + num2str(obj.DeviceID)); % Example: DN_DS_Ctrl.exe FLCSwitch 1110 -CAM1
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
                error("Unable to toggle a set of LEDs!");
            end
            result = true;
        end

        function result = SetLEDBrightness(obj, level)
            result = false;
            assert(obj.LedControl, "Unable to switch LED states. Dino-Lite DOS Control installation does not exist.");
            assert(obj.LEDs, "Unable to switch LED states. LEDs are disabled.");
            if (level < 1 || level > 6)
                error("The set LED brightness level must be in the range of 1-6!");
            end
            try
                dos(obj.EXE_PATH + " FLCLevel " + num2str(level) + " -CAM" + num2str(obj.DeviceID)); % Example: DN_DS_Ctrl.exe FLCLevel 1 -CAM1
                obj.Brightness = level;
            catch e
                fprintf(1, "Error identifier:\n%s\n", e.identifier);
                fprintf(1, "Error message:\n%s\n", e.message);
                error("Unable to set LED brightness!");
            end
            result = true;
        end

    end

    methods (Static)

        function found = CheckTool()
            found = isfile(DinoLite.EXE_PATH);
        end

    end

end