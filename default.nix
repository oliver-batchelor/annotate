{}:

(import ./reflex-platform {}).project ({ pkgs, ... }: {
  packages = {
    common = ./common;
    server = ./server;
    client = ./client;
    stm-persist = ./stm-persist;
    reflex-html = ./reflex-html;
    generic-lens-labels = ./generic-lens-labels;
    stitch = ./stitch;
  };

  shells = {
#    ghc = ["common" "server" "client"];
    ghc8_2 = ["common" "server" "client"];
    ghcjs = ["common" "client"];
  };
})
