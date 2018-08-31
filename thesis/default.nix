{ pkgs     ? import ../nixpkgs.pinned.nix 
, mkPandoc ? import ./nix-mkPandoc/mkPandoc.nix { inherit pkgs; }
, eisvogel ? import ./nix-mkPandoc/eisvogel.latex.nix { inherit pkgs; }
, jcis-csl ? import ./nix-mkPandoc/journal-of-computer-information-systems.csl.nix { inherit pkgs; }
, pandoc-citeproc ? pkgs.haskellPackages.pandoc-citeproc
, date ? "2018-??-??"
, sha256 ? "???"
, commit ? null
, commitHash ? if commit != null then (builtins.fromJSON commit).object.sha else "???"
, verbose ? false
}:
mkPandoc {
  name         = "dakka-thesis.pdf";
  version      = "0.2.0";
  src          = ./.;
  documentFile = ./main.md;
  bibliography = ./bibliography.bib;
  filters      = [ pandoc-citeproc ];
  toc          = true;
  template = eisvogel;
  csl      = jcis-csl;
  listings = true;
  top-level-division = "section";
  number-sections = true;
  variables = {
    inherit date;
    geometry     = "left=3.5cm, right=2.5cm";
    toc-own-page = true;
    titlepage    = true;
  };
  include-before-body = builtins.toFile "header.tex" ''
    \begin{tabular}{ r l }
      {\bf Commit:} & \verb|${commitHash}| \\
      {\bf sha256:} & \verb|${sha256}| \\
    \end{tabular}
    \\
    To verify the hash compare the sha256 hash with the output of:\\
    \lstinline[language=sh]{nix-prefetch-url --unpack "https://github.com/chisui/dakka/archive/${commitHash}.tar.gz"}.
  '';
  inherit verbose; 
}
