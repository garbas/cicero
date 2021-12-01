final: prev:

let
  commonName = "workflow-action-script";

  runner = drv:
    prev.writers.writeBashBin "${drv.name}-runner" ''
      set -exuo pipefail

      export PATH="$PATH:${
        prev.lib.makeBinPath
        (with final; [ coreutils gnutar xz ])
      }"
      export CICERO_SCRIPT=$(< "$1")
      exec ${drv}
    '';
in {
  run-bash = runner (prev.writers.writeBash "${commonName}-bash" ''
    eval "$CICERO_SCRIPT"
  '');

  run-python = runner (prev.writers.writePython3 "${commonName}-python" { } ''
    import os
    eval(os.environ['CICERO_SCRIPT'])
  '');

  run-perl = runner (prev.writers.writePerl "${commonName}-perl" { } ''
    eval $ENV{'CICERO_SCRIPT'};
  '');

  run-js = runner (prev.writers.writeJS "${commonName}-js" { } ''
    const process = require('process')
    eval(process.env.CICERO_SCRIPT)
  '');
}
