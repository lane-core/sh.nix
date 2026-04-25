# Generates NixOS, nix-darwin, and home-manager modules for a POSIX-compatible
# shell, following the established conventions of programs.bash, programs.zsh,
# and programs.fish.
#
# Parameters:
#   name               - string: shell name, e.g. "ksh"
#   package            - derivation or null: default shell package
#   initFiles          - attrset describing initialization files (see below)
#   extraOptions       - optional module fragment merged into options.programs.<name>
#   extraConfig        - optional module fragment merged into config.programs.<name>
#   programmableOptions
#     - attrset of { type, default, description, target, generator }
#     - target must be one of: shellInit | loginShellInit | interactiveShellInit
#                              | promptInit | logoutExtra
#     - generator: function from user-configured value → shell code string
#
# initFiles schema:
#   {
#     profile = {
#       etcName  = "profile";      # basename in /etc  (omit → no system-wide file)
#       homePath = ".profile";     # basename in ~     (omit → no home-manager file)
#       when     = "login";        # "always" | "login" | "interactive"
#       envVar   = null;           # if set, login file exports this var
#     };
#     rc = {
#       etcName  = "kshrc";
#       homePath = ".kshrc";
#       when     = "interactive";
#       envVar   = "ENV";          # login file will export ENV pointing to this file
#     };
#   }
#
# Platform handling is fully internal:
#   • NixOS     — writes /etc/${etcName} directly, except /etc/profile which is
#                 merged into the shared file managed by programs.bash.
#   • nix-darwin — writes /etc/${etcName}; for /etc/profile includes
#                 knownSha256Hashes so activation can back up the stock file.
#   • home-manager — writes ~/${homePath}.

{
  name,
  package,
  initFiles,
  extraOptions ? { },
  extraConfig ? { },
  programmableOptions ? { },
}:

let
  validTargets = [
    "shellInit"
    "loginShellInit"
    "interactiveShellInit"
    "promptInit"
    "logoutExtra"
  ];

  isEmpty = val: val == null || val == [ ] || val == { } || val == false || val == "";

  # Build option declarations from programmableOptions (needs lib at call site).
  mkProgrammableOptionsDecl =
    lib:
    lib.mapAttrs (
      _: def:
      lib.mkOption {
        type = def.type;
        default = def.default;
        description = def.description;
      }
    ) programmableOptions;

  # Build an attrset of target → generated shell code string.
  # This is computed in the module's let-binding and interpolated
  # directly into init file templates, avoiding self-reference in config.
  mkProgrammableCode =
    lib: cfg:
    let
      optionsList = lib.mapAttrsToList (n: v: v // { _optName = n; }) programmableOptions;
      targets = lib.unique (map (v: v.target) optionsList);

      badTargets = lib.filter (t: !(lib.elem t validTargets)) targets;

      mkCode =
        target:
        let
          opts = lib.filter (v: v.target == target) optionsList;
          snippets = lib.filter (s: s != "") (
            map (
              opt:
              let
                val = cfg.${opt._optName};
              in
              if isEmpty val then "" else opt.generator val
            ) opts
          );
        in
        lib.concatStringsSep "\n" snippets;
    in
    lib.throwIf (badTargets != [ ])
      "mkPosixShellModule: invalid programmableOptions target(s): ${lib.concatStringsSep ", " badTargets}; expected one of: ${lib.concatStringsSep ", " validTargets}"
      (
        lib.listToAttrs (
          map (target: {
            name = target;
            value = mkCode target;
          }) targets
        )
      );
in
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

      progDecl = mkProgrammableOptionsDecl lib;
      progCode = mkProgrammableCode lib cfg;

      # Files that get a system-wide /etc entry on NixOS.
      nixosFiles = lib.filterAttrs (_: f: f ? etcName) initFiles;

      # Login file used for guard variables and done markers.
      loginFileDef = lib.findFirst (f: f.when == "login" && f ? etcName) null (lib.attrValues initFiles);

      doneVarName =
        if loginFileDef != null then "__ETC_${upper loginFileDef.etcName}_DONE" else "__ETC_PROFILE_DONE";

      aliasesStr = sh.mkAliases cfg.shellAliases;

      # Files that have an envVar (the login file will export these).
      envTargets = lib.filterAttrs (_: f: f.envVar != null) initFiles;

      # Generate a single system-wide init file.
      mkSystemFile =
        fileName: fileDef:
        let
          etcName = fileDef.etcName;
          guardVar = "__ETC_${upper etcName}_SOURCED";
          noSysVar = "NOSYS${upper name}";

          contentForWhen =
            if fileDef.when == "always" then
              ''
                ${progCode.shellInit or ""}${cfg.shellInit}
              ''
            else if fileDef.when == "login" then
              ''
                ${progCode.shellInit or ""}${cfg.shellInit}
                ${progCode.loginShellInit or ""}${cfg.loginShellInit}
                ${rcSourceForLogin}
              ''
            else if fileDef.when == "interactive" then
              ''
                ${lib.optionalString (loginFileDef != null) ''
                  # If the login file was not loaded in a parent process, source it.
                  if [ -z "${doneVarName}" ]; then
                      . /etc/${loginFileDef.etcName}
                  fi
                ''}
                # We are not always an interactive shell.
                if [ -n "$PS1" ]; then
                    ${cfge.interactiveShellInit}
                    ${progCode.interactiveShellInit or ""}${cfg.interactiveShellInit}
                    ${aliasesStr}
                    ${progCode.promptInit or ""}${cfg.promptInit}
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
                mkExport = _: f: if f ? etcName then ''export ${f.envVar}="/etc/${f.etcName}"'' else "";
              in
              lib.concatStringsSep "\n" (lib.filter (s: s != "") (lib.mapAttrsToList mkExport envTargets))
            else
              "";

          guard =
            if fileDef.when == "interactive" then
              ''
                if [ -n "''$${guardVar}" ] || [ -n "''$${noSysVar}" ]; then return; fi
                ${guardVar}=1
              ''
            else
              ''
                if [ -n "''$${guardVar}" ]; then return; fi
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

      # On NixOS /etc/profile is owned by programs.bash; writing it directly
      # would conflict.  Filter it out — its content is merged instead.
      nixosFilesToWrite = lib.filterAttrs (_: f: f.etcName != "profile") nixosFiles;

      systemFiles = lib.mapAttrs' mkSystemFile nixosFilesToWrite;

      # Content appended to the shared /etc/profile via mkAfter.
      profileMerge =
        let
          loginProfile = lib.findFirst (f: f.when == "login" && f ? etcName && f.etcName == "profile") null (
            lib.attrValues initFiles
          );
        in
        lib.optionalString (loginProfile != null) ''
          # Set up environment.
          if [ -z "$__NIXOS_SET_ENVIRONMENT_DONE" ]; then
              . ${config.system.build.setEnvironment}
          fi

          ${progCode.shellInit or ""}${cfg.shellInit}
          ${progCode.loginShellInit or ""}${cfg.loginShellInit}
          ${rcSourceForLogin}
        '';

      # Source interactive init files from login files (standard POSIX practice).
      rcSourceForLogin =
        let
          interactiveFiles = lib.filterAttrs (_: f: f.when == "interactive") nixosFiles;
          mkSource = _: f: ''[ -r "/etc/${f.etcName}" ] && . "/etc/${f.etcName}"'';
        in
        if interactiveFiles == { } then
          ""
        else
          ''
            # Source interactive init files for login shells.
            case $- in *i*)
                ${lib.concatStringsSep "\n    " (lib.mapAttrsToList mkSource interactiveFiles)}
                ;;
            esac
          '';

      # If there are interactive files with envVar(s), set them globally so
      # the shell picks them up via setEnvironment.
      envVarsFromInteractive = lib.mapAttrs' (_: f: {
        name = f.envVar;
        value = "/etc/${f.etcName}";
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
      // extraOptions
      // progDecl;

      config = lib.mkIf cfg.enable (
        {
          programs.${name}.shellAliases = lib.mapAttrs (name: lib.mkDefault) cfge.shellAliases;

          environment.etc =
            systemFiles
            // lib.optionalAttrs (profileMerge != "") {
              profile = {
                text = lib.mkAfter profileMerge;
              };
            };

          environment.variables = lib.mapAttrs (_: lib.mkDefault) envVarsFromInteractive;

          environment.systemPackages = lib.optional (cfg.package != null) cfg.package;

          environment.shells = lib.optionals (cfg.package != null) [
            "/run/current-system/sw/bin/${name}"
            "${cfg.package}/bin/${name}"
          ];
        }
        // extraConfig
      );
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

      progDecl = mkProgrammableOptionsDecl lib;
      progCode = mkProgrammableCode lib cfg;

      aliasesStr = sh.mkAliases cfg.shellAliases;

      # Interactive files that get a home-manager entry (login files are
      # handled by appending to the shared ~/.profile via mkAfter).
      hmFiles = lib.filterAttrs (_: f: f ? homePath && f.when != "login") initFiles;

      # Interactive file definitions for login shell sourcing.
      interactiveHmFiles = lib.filterAttrs (_: f: f.when == "interactive") hmFiles;

      # Build the ~/.profile appendix: export ENV and source ~/.<sh>rc.
      profileAppendix =
        let
          envExports = lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              _: f:
              lib.optionalString (f ? homePath && f.envVar != null) ''
                export ${f.envVar}="${config.home.homeDirectory}/${f.homePath}"
              ''
            ) interactiveHmFiles
          );
          rcSources = lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              _: f:
              lib.optionalString (f ? homePath) ''
                [ -r "${config.home.homeDirectory}/${f.homePath}" ] && . "${config.home.homeDirectory}/${f.homePath}"
              ''
            ) interactiveHmFiles
          );
        in
        lib.optionalString (interactiveHmFiles != { }) ''
          set -u
          # ${name} shell configuration.
          ${envExports}
          case $- in *i*)
              ${rcSources}
              ;;
          esac
        '';

      # Generate a single user init file.
      mkUserFile =
        fileName: fileDef:
        let
          homePath = fileDef.homePath;
          guardVar = "__HM_${upper name}_${upper (lib.replaceStrings [ "." ] [ "_" ] homePath)}_SOURCED";

          contentForWhen =
            if fileDef.when == "always" then
              ''
                ${progCode.shellInit or ""}${cfg.shellInit}
              ''
            else if fileDef.when == "interactive" then
              ''
                # Only execute for interactive shells.
                case $- in *i*) ;; *) return;; esac

                ${progCode.interactiveShellInit or ""}${cfg.interactiveShellInit}
                ${aliasesStr}
                ${progCode.promptInit or ""}${cfg.promptInit}
              ''
            else
              throw "mkPosixShellModule: unknown 'when' value '${fileDef.when}' for file '${fileName}'";

          guard = ''
            if [ -n "''$${guardVar}" ]; then return; fi
            ${guardVar}=1
          '';
        in
        {
          name = homePath;
          value = {
            text = ''
              ${guard}
              ${contentForWhen}

              ${cfg.${fileName + "Extra"} or ""}
            '';
          };
        };

      userFiles = lib.mapAttrs' mkUserFile hmFiles;

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
        // extraOptions
        // progDecl;
      };

      config = lib.mkIf cfg.enable (
        lib.mkMerge [
          {
            programs.${name}.shellAliases = lib.mapAttrs (name: lib.mkDefault) config.home.shellAliases;

            home.file = userFiles;

            home.packages = lib.optional (cfg.package != null) cfg.package;
          }
          (lib.optionalAttrs (interactiveHmFiles != { }) {
            home.file.".profile".text = lib.mkBefore ''
              set +u

            '';
          })
          (lib.optionalAttrs (interactiveHmFiles != { }) {
            home.file.".profile".text = lib.mkAfter profileAppendix;
          })
          extraConfig
        ]
      );
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

      progDecl = mkProgrammableOptionsDecl lib;
      progCode = mkProgrammableCode lib cfg;

      # Files that get a system-wide /etc entry on nix-darwin.
      darwinFilesDef = lib.filterAttrs (_: f: f ? etcName) initFiles;

      loginFileDef = lib.findFirst (f: f.when == "login" && f ? etcName) null (lib.attrValues initFiles);

      doneVarName =
        if loginFileDef != null then "__ETC_${upper loginFileDef.etcName}_DONE" else "__ETC_PROFILE_DONE";

      aliasesStr = sh.mkAliases cfg.shellAliases;

      envTargets = lib.filterAttrs (_: f: f.envVar != null) initFiles;

      mkDarwinFile =
        fileName: fileDef:
        let
          etcName = fileDef.etcName;
          guardVar = "__ETC_${upper etcName}_SOURCED";

          contentForWhen =
            if fileDef.when == "always" then
              ''
                ${progCode.shellInit or ""}${cfg.shellInit}
              ''
            else if fileDef.when == "login" then
              ''
                ${progCode.shellInit or ""}${cfg.shellInit}
                ${progCode.loginShellInit or ""}${cfg.loginShellInit}
                ${rcSourceForLogin}
              ''
            else if fileDef.when == "interactive" then
              ''
                ${lib.optionalString (loginFileDef != null) ''
                  if [ -z "${doneVarName}" ]; then
                      . /etc/${loginFileDef.etcName}
                  fi
                ''}
                if [ -n "$PS1" ]; then
                    ${cfge.interactiveShellInit}
                    ${progCode.interactiveShellInit or ""}${cfg.interactiveShellInit}
                    ${aliasesStr}
                    ${progCode.promptInit or ""}${cfg.promptInit}
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
                mkExport = _: f: if f ? etcName then ''export ${f.envVar}="/etc/${f.etcName}"'' else "";
              in
              lib.concatStringsSep "\n" (lib.filter (s: s != "") (lib.mapAttrsToList mkExport envTargets))
            else
              "";

          guard = ''
            if [ -n "''$${guardVar}" ]; then return; fi
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
          }
          // lib.optionalAttrs (etcName == "profile") {
            knownSha256Hashes = [
              # macOS stock /etc/profile (Big Sur through Sequoia)
              "a3fe9f414586c0d3cacbe3b6920a09d8718e503bca22e23fef882203bf765065"
            ];
          };
        };

      # Source interactive init files from login files (standard POSIX practice).
      rcSourceForLogin =
        let
          interactiveFiles = lib.filterAttrs (_: f: f.when == "interactive") darwinFilesDef;
          mkSource = _: f: ''[ -r "/etc/${f.etcName}" ] && . "/etc/${f.etcName}"'';
        in
        if interactiveFiles == { } then
          ""
        else
          ''
            # Source interactive init files for login shells.
            case $- in *i*)
                ${lib.concatStringsSep "\n    " (lib.mapAttrsToList mkSource interactiveFiles)}
                ;;
            esac
          '';

      darwinFiles = lib.mapAttrs' mkDarwinFile darwinFilesDef;

      # If there are interactive files with envVar(s), set them globally so
      # the shell picks them up.
      envVarsFromInteractive = lib.mapAttrs' (_: f: {
        name = f.envVar;
        value = "/etc/${f.etcName}";
      }) (lib.filterAttrs (_: f: f.envVar != null && f.when == "interactive") darwinFilesDef);

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
      // extraOptions
      // progDecl;

      config = lib.mkIf cfg.enable (
        {
          programs.${name}.shellAliases = lib.mapAttrs (name: lib.mkDefault) cfge.shellAliases;

          environment.etc = darwinFiles;

          environment.variables = lib.mapAttrs (_: lib.mkDefault) envVarsFromInteractive;

          environment.systemPackages = lib.optional (cfg.package != null) cfg.package;

          environment.shells = lib.optionals (cfg.package != null) [
            "/run/current-system/sw/bin/${name}"
            "${cfg.package}/bin/${name}"
          ];
        }
        // extraConfig
      );
    };
}
