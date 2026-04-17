# POSIX shell script generation helpers.
# These mirror home-manager's lib.shell utilities.

{ lib }:

rec {
  # Produces: export NAME="value"
  export = n: v: ''export ${n}="${toString v}"'';

  # Given an attrset of shell variables, produces export statements.
  exportAll =
    vars:
    let
      mkExport = name: export name vars.${name};
    in
    lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: mkExport name) vars);

  # Produces: PREPEND${VAR:+:}$VAR
  prependToVar =
    sep: n: v:
    "${lib.concatStringsSep sep v}\${${n}:+${sep}}\$${n}";

  # Given an attrset of aliases, produces POSIX alias lines.
  # Filters out null values and uses `--` to protect against aliases
  # starting with `-`.
  mkAliases =
    aliases:
    let
      mkAlias =
        name: value:
        lib.optionalString (
          value != null
        ) "alias -- ${lib.escapeShellArg name}=${lib.escapeShellArg (toString value)}";
    in
    lib.concatStringsSep "\n" (lib.mapAttrsToList mkAlias aliases);

  # Wrap a list of strings to a given line width.
  wrapLines =
    items: maxWidth:
    let
      step =
        acc: item:
        let
          potentialLine = if acc.currentLine == "" then item else "${acc.currentLine} ${item}";
        in
        if lib.stringLength potentialLine <= maxWidth then
          acc // { currentLine = potentialLine; }
        else
          acc
          // {
            finishedLines = acc.finishedLines ++ [ acc.currentLine ];
            currentLine = item;
          };
      foldResult = lib.foldl' step {
        finishedLines = [ ];
        currentLine = "";
      } items;
    in
    foldResult.finishedLines ++ lib.optional (foldResult.currentLine != "") foldResult.currentLine;
}
