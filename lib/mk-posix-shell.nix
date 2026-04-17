# Generates NixOS, nix-darwin, and home-manager modules for a POSIX-compatible
# shell, following the established conventions of programs.bash, programs.zsh,
# and programs.fish.
#
# Parameters:
#   name          - string: shell name, e.g. "ksh"
#   package       - derivation or null: default shell package
#   initFiles     - attrset describing initialization files (see below)
#   extraOptions  - optional module fragment merged into options.programs.<name>
#   extraConfig   - optional module fragment merged into config.programs.<name>
#
# initFiles schema:
#   {
#     profile = {
#       nixos       = null;                     # null → don't write file on NixOS
#       homeManager = { homePath = ".profile"; };
#       darwin      = { etcName = "profile"; };
#       when        = "login";                  # "always" | "login" | "interactive"
#       envVar      = null;                     # if set, login file exports this var
#     };
#     rc = {
#       nixos       = { etcName = "kshrc"; };
#       homeManager = { homePath = ".kshrc"; };
#       darwin      = { etcName = "kshrc"; };
#       when        = "interactive";
#       envVar      = "ENV";    # login file will export ENV pointing to this file
#     };
#   }
#
# When nixos is null for a login file but an interactive file has envVar,
# the NixOS module sets environment.variables.${envVar} globally so the
# shell picks up the interactive file without writing a conflicting login file.

{
  name,
  package,
  initFiles,
  extraOptions ? { },
  extraConfig ? { },
}:

{
  # ─── NixOS module ───
  nixosModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.programs.${name};
      cfge = config.environment;

      sh = import ./shell-script.nix { inherit lib; };

      upper = s: lib.toUpper s;

      # Files that actually get written on NixOS (nixos != null).
      nixosFiles = lib.filterAttrs (_: f: f.nixos or null != null) initFiles;

      loginFileDef = lib.findFirst (f: f.when == "login") null (lib.attrValues nixosFiles);

      doneVarName =
        if loginFileDef != null && loginFileDef.nixos ? etcName then
          "__ETC_${upper loginFileDef.nixos.etcName}_DONE"
        else
          "__ETC_PROFILE_DONE";

      aliasesStr = sh.mkAliases cfg.shellAliases;

      # Files that have an envVar (the login file will export these).
      envTargets = lib.filterAttrs (_: f: f.envVar != null) initFiles;

      # Generate a single system-wide init file.
      mkSystemFile =
        fileName: fileDef:
        let
          etcName = fileDef.nixos.etcName;
          guardVar = "__ETC_${upper etcName}_SOURCED";
          noSysVar = "NOSYS${upper name}";

          contentForWhen =
            if fileDef.when == "always" then
              ''
                ${cfg.shellInit}
              ''
            else if fileDef.when == "login" then
              ''
                ${cfg.shellInit}
                ${cfg.loginShellInit}
              ''
            else if fileDef.when == "interactive" then
              ''
                # If the login file was not loaded in a parent process, source it.
                if [ -z "${doneVarName}" ]; then
                    . /etc/${loginFileDef.nixos.etcName}
                fi

                # We are not always an interactive shell.
                if [ -n "$PS1" ]; then
                    ${cfge.interactiveShellInit}
                    ${cfg.interactiveShellInit}
                    ${aliasesStr}
                    ${cfg.promptInit}
                fi
              ''
            else
              throw "mkPosixShellModule: unknown 'when' value '${fileDef.when}' for file '${fileName}'";

          envSetup =
            if fileDef.when == "login" || fileDef.when == "interactive" then
              ''
                # Set up environment.
                if [ -z "$__NIXOS_SET_ENVIRONMENT_DONE" ]; then
                    . ${config.system.build.setEnvironment}
                fi
              ''
            else
              "";

          # Login file exports envVar(s) pointing to their target files.
          envVarSetup =
            if fileDef.when == "login" then
              let
                mkExport = _: f: ''export ${f.envVar}="/etc/${f.nixos.etcName}"'';
              in
              lib.concatStringsSep "\n" (lib.mapAttrsToList mkExport envTargets)
            else
              "";

          guard =
            if fileDef.when == "interactive" then
              ''
                if [ -n "$${guardVar}" ] || [ -n "$${noSysVar}" ]; then return; fi
                ${guardVar}=1
              ''
            else
              ''
                if [ -n "$${guardVar}" ]; then return; fi
                ${guardVar}=1
              '';

          doneMarker =
            if fileDef.when == "login" then
              ''
                export ${doneVarName}=1
              ''
            else
              "";

          filePath = "/etc/${etcName}";
        in
        {
          name = etcName;
          value = {
            text = ''
              # ${filePath}: DO NOT EDIT -- this file has been generated automatically.

              ${guard}
              ${doneMarker}
              ${envSetup}
              ${envVarSetup}
              ${contentForWhen}

              # Read system-wide modifications.
              if test -f ${filePath}.local; then
                  . ${filePath}.local
              fi
            '';
          };
        };

      systemFiles = lib.mapAttrs' mkSystemFile nixosFiles;

      # If we didn't write a login file on NixOS but there are interactive
      # files with envVar(s), set them globally so the shell picks them up
      # via setEnvironment (which bash's /etc/profile already sources).
      envVarsFromInteractive = lib.mapAttrs' (_: f: {
        name = f.envVar;
        value = "/etc/${f.nixos.etcName}";
      }) (lib.filterAttrs (_: f: f.envVar != null && f.when == "interactive") nixosFiles);

    in
    {
      options.programs.${name} = {
        enable = lib.mkEnableOption "${name} shell";

        package = lib.mkPackageOption pkgs name {
          default = package;
          nullable = true;
        };

        shellAliases = lib.mkOption {
          default = { };
          description = ''
            Set of aliases for ${name} shell, which overrides
            {option}`environment.shellAliases`.
          '';
          type = with lib.types; attrsOf (nullOr (either str path));
        };

        shellInit = lib.mkOption {
          default = "";
          description = ''
            Shell script code called during ${name} shell initialisation.
          '';
          type = lib.types.lines;
        };

        loginShellInit = lib.mkOption {
          default = "";
          description = ''
            Shell script code called during ${name} login shell initialisation.
          '';
          type = lib.types.lines;
        };

        interactiveShellInit = lib.mkOption {
          default = "";
          description = ''
            Shell script code called during ${name} interactive shell initialisation.
          '';
          type = lib.types.lines;
        };

        promptInit = lib.mkOption {
          default = "";
          description = ''
            Shell script code used to initialise the ${name} prompt.
          '';
          type = lib.types.lines;
        };

        logoutExtra = lib.mkOption {
          default = "";
          description = ''
            Shell script code called when logging out of an interactive ${name} shell.
          '';
          type = lib.types.lines;
        };
      }
      // extraOptions;

      config =
        lib.mkIf cfg.enable {
          programs.${name}.shellAliases = lib.mapAttrs (name: lib.mkDefault) cfge.shellAliases;

          environment.etc = systemFiles;

          environment.variables = lib.mapAttrs (_: lib.mkDefault) envVarsFromInteractive;

          environment.systemPackages = lib.optional (cfg.package != null) cfg.package;

          environment.shells = lib.optionals (cfg.package != null) [
            "/run/current-system/sw/bin/${name}"
            "${cfg.package}/bin/${name}"
          ];
        }
        // extraConfig;
    };

  # ─── Home-manager module ───
  homeManagerModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.programs.${name};

      sh = import ./shell-script.nix { inherit lib; };

      upper = s: lib.toUpper s;

      aliasesStr = sh.mkAliases cfg.shellAliases;

      # Files that have an envVar (the login file will export these).
      envTargets = lib.filterAttrs (_: f: f.envVar != null) initFiles;

      # Generate a single user init file.
      mkUserFile =
        fileName: fileDef:
        let
          homePath = fileDef.homeManager.homePath;
          guardVar = "__HM_${upper name}_${upper (lib.replaceStrings [ "." ] [ "_" ] homePath)}_SOURCED";

          contentForWhen =
            if fileDef.when == "always" then
              ''
                ${cfg.shellInit}
              ''
            else if fileDef.when == "login" then
              ''
                ${cfg.shellInit}
                ${cfg.loginShellInit}
              ''
            else if fileDef.when == "interactive" then
              ''
                # Only execute for interactive shells.
                case $- in *i*) ;; *) return;; esac

                ${cfg.interactiveShellInit}
                ${aliasesStr}
                ${cfg.promptInit}
              ''
            else
              throw "mkPosixShellModule: unknown 'when' value '${fileDef.when}' for file '${fileName}'";

          sessionVars =
            if fileDef.when == "login" then
              ''
                . "${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh"
              ''
            else
              "";

          # Login file exports envVar(s) pointing to their target files.
          envVarSetup =
            if fileDef.when == "login" then
              let
                mkExport = _: f: ''export ${f.envVar}="${config.home.homeDirectory}/${f.homeManager.homePath}"'';
              in
              lib.concatStringsSep "\n" (lib.mapAttrsToList mkExport envTargets)
            else
              "";

          guard = ''
            if [ -n "$${guardVar}" ]; then return; fi
            ${guardVar}=1
          '';
        in
        {
          name = homePath;
          value = {
            text = ''
              ${guard}
              ${sessionVars}
              ${envVarSetup}
              ${contentForWhen}

              ${cfg.${fileName + "Extra"} or ""}
            '';
          };
        };

      userFiles = lib.mapAttrs' mkUserFile initFiles;

      integrationOptionName = "enable${
        lib.toUpper (lib.substring 0 1 name + lib.substring 1 (-1) name)
      }Integration";
    in
    {
      options = {
        programs.${name} = {
          enable = lib.mkEnableOption "${name} shell";

          package = lib.mkPackageOption pkgs name {
            default = package;
            nullable = true;
          };

          shellAliases = lib.mkOption {
            default = { };
            description = ''
              An attribute set that maps aliases (the top level attribute names in
              this option) to command strings or directly to build outputs.
            '';
            type = with lib.types; attrsOf (nullOr (either str path));
          };

          shellInit = lib.mkOption {
            default = "";
            description = ''
              Shell script code called during ${name} shell initialisation.
            '';
            type = lib.types.lines;
          };

          loginShellInit = lib.mkOption {
            default = "";
            description = ''
              Shell script code called during ${name} login shell initialisation.
            '';
            type = lib.types.lines;
          };

          interactiveShellInit = lib.mkOption {
            default = "";
            description = ''
              Shell script code called during ${name} interactive shell initialisation.
            '';
            type = lib.types.lines;
          };

          promptInit = lib.mkOption {
            default = "";
            description = ''
              Shell script code used to initialise the ${name} prompt.
            '';
            type = lib.types.lines;
          };

          logoutExtra = lib.mkOption {
            default = "";
            description = ''
              Extra commands that should be run when logging out of an
              interactive ${name} shell.
            '';
            type = lib.types.lines;
          };
        }
        // extraOptions;

        home.shell.${integrationOptionName} = lib.mkOption {
          type = lib.types.bool;
          default = config.home.shell.enableShellIntegration or true;
          example = false;
          description = ''
            Whether to globally enable ${name} shell integration.
          '';
        };
      };

      config =
        lib.mkIf cfg.enable {
          programs.${name}.shellAliases = lib.mapAttrs (name: lib.mkDefault) config.home.shellAliases;

          home.file = userFiles;

          home.packages = lib.optional (cfg.package != null) cfg.package;
        }
        // extraConfig;
    };

  # ─── nix-darwin module ───
  darwinModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.programs.${name};
      cfge = config.environment;

      sh = import ./shell-script.nix { inherit lib; };

      upper = s: lib.toUpper s;

      loginFileDef = lib.findFirst (f: f.when == "login") null (lib.attrValues initFiles);

      doneVarName =
        if loginFileDef != null && loginFileDef.darwin ? etcName then
          "__ETC_${upper loginFileDef.darwin.etcName}_DONE"
        else
          "__ETC_PROFILE_DONE";

      aliasesStr = sh.mkAliases cfg.shellAliases;

      envTargets = lib.filterAttrs (_: f: f.envVar != null) initFiles;

      mkDarwinFile =
        fileName: fileDef:
        let
          etcName = fileDef.darwin.etcName;
          guardVar = "__ETC_${upper etcName}_SOURCED";

          contentForWhen =
            if fileDef.when == "always" then
              ''
                ${cfg.shellInit}
              ''
            else if fileDef.when == "login" then
              ''
                ${cfg.shellInit}
                ${cfg.loginShellInit}
              ''
            else if fileDef.when == "interactive" then
              ''
                if [ -z "${doneVarName}" ]; then
                    . /etc/${loginFileDef.darwin.etcName}
                fi

                if [ -n "$PS1" ]; then
                    ${cfge.interactiveShellInit}
                    ${cfg.interactiveShellInit}
                    ${aliasesStr}
                    ${cfg.promptInit}
                fi
              ''
            else
              throw "mkPosixShellModule: unknown 'when' value '${fileDef.when}' for file '${fileName}'";

          envSetup =
            if fileDef.when == "login" || fileDef.when == "interactive" then
              ''
                if [ -z "$__NIX_DARWIN_SET_ENVIRONMENT_DONE" ]; then
                    . ${config.system.build.setEnvironment}
                fi
              ''
            else
              "";

          envVarSetup =
            if fileDef.when == "login" then
              let
                mkExport = _: f: ''export ${f.envVar}="/etc/${f.darwin.etcName}"'';
              in
              lib.concatStringsSep "\n" (lib.mapAttrsToList mkExport envTargets)
            else
              "";

          guard = ''
            if [ -n "$${guardVar}" ]; then return; fi
            ${guardVar}=1
          '';

          doneMarker =
            if fileDef.when == "login" then
              ''
                export ${doneVarName}=1
              ''
            else
              "";

          filePath = "/etc/${etcName}";
        in
        {
          name = etcName;
          value = {
            text = ''
              # ${filePath}: DO NOT EDIT -- this file has been generated automatically.

              ${guard}
              ${doneMarker}
              ${envSetup}
              ${envVarSetup}
              ${contentForWhen}

              # Read system-wide modifications.
              if test -f ${filePath}.local; then
                  . ${filePath}.local
              fi
            '';
          };
        };

      darwinFiles = lib.mapAttrs' mkDarwinFile (
        lib.filterAttrs (_: f: f.darwin or null != null) initFiles
      );

    in
    {
      options.programs.${name} = {
        enable = lib.mkEnableOption "${name} shell";

        package = lib.mkPackageOption pkgs name {
          default = package;
          nullable = true;
        };

        shellAliases = lib.mkOption {
          default = { };
          type = with lib.types; attrsOf (nullOr (either str path));
          description = ''
            Set of aliases for ${name} shell, which overrides
            {option}`environment.shellAliases`.
          '';
        };

        shellInit = lib.mkOption {
          default = "";
          type = lib.types.lines;
          description = ''
            Shell script code called during ${name} shell initialisation.
          '';
        };

        loginShellInit = lib.mkOption {
          default = "";
          type = lib.types.lines;
          description = ''
            Shell script code called during ${name} login shell initialisation.
          '';
        };

        interactiveShellInit = lib.mkOption {
          default = "";
          type = lib.types.lines;
          description = ''
            Shell script code called during ${name} interactive shell initialisation.
          '';
        };

        promptInit = lib.mkOption {
          default = "";
          type = lib.types.lines;
          description = ''
            Shell script code used to initialise the ${name} prompt.
          '';
        };

        logoutExtra = lib.mkOption {
          default = "";
          type = lib.types.lines;
          description = ''
            Shell script code called during ${name} login shell logout.
          '';
        };
      }
      // extraOptions;

      config =
        lib.mkIf cfg.enable {
          programs.${name}.shellAliases = lib.mapAttrs (name: lib.mkDefault) cfge.shellAliases;

          environment.etc = darwinFiles;

          environment.systemPackages = lib.optional (cfg.package != null) cfg.package;

          environment.shells = lib.optionals (cfg.package != null) [
            "/run/current-system/sw/bin/${name}"
            "${cfg.package}/bin/${name}"
          ];
        }
        // extraConfig;
    };
}
