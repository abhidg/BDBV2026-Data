let
  nixpkgs = fetchTarball "https://github.com/NixOS/nixpkgs/tarball/nixos-26.05";
  pkgs = import nixpkgs {
    config = { };
    overlays = [ ];
  };
in

pkgs.mkShellNoCC {
  packages = with pkgs; [
    python313
    python313Packages.pyshp
    python313Packages.pyyaml
    python313Packages.shapely
    python313Packages.pytest
    python313Packages.geopandas
    R
    rPackages.sf
    rPackages.terra
    rPackages.dplyr
    rPackages.ggplot2
    rPackages.here
    rPackages.ncdf4
    rPackages.osrm
    rPackages.testthat
    rPackages.tictoc
  ];
}
