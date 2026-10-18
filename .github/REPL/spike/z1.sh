#!/usr/bin/env bash
# plan 01 Z.1 spike (no engine code): rea --json -> projected CSV in DIR -> bin2md --corpus DIR.
# usage: z1.sh DIR BIN...      (BIN absolute ELF paths; first is the subject, others are controls)
# Tables: linkage.csv (from rea section_headers Evidence), needed.csv (objdump -p, NOT rea Evidence:
# rea 6.7.0 has no dynamic-section op), symbols.csv (from rea symbols Evidence), manifest.csv.
set -euo pipefail
DIR=$1; shift
REA=${REA:-"node /workspace/rea/scripts/rea.mjs"}
mkdir -p "$DIR/raw"
echo 'binary,linkage,has_interp,has_dynamic,has_dynsym,dynamic_exports,source,evidence_id' > "$DIR/linkage.csv"
echo 'binary,library,source' > "$DIR/needed.csv"
echo 'binary,symbol,kind,source' > "$DIR/exports.csv"
echo 'binary,addr,scope,type,section,size,name,exported_dynamic,source,evidence_id' > "$DIR/symbols.csv"
echo 'binary,op,evidence_id,sha256,provider,rc,bytes' > "$DIR/manifest.csv"
for B in "$@"; do
  n=$(basename "$B")
  for op in section_headers symbols; do
    f="$DIR/raw/$n.$op.rea.prg.json"; rc=0
    $REA inspect-with-objdump "$B" $op --format json > "$f" 2>"$f.err" || rc=$?
    jq -r --arg b "$n" --arg op "$op" --arg rc "$rc" --arg sz "$(stat -c%s "$f")" \
      '[$b,$op,.evidence_id,.subject.digest.sha256,(.provider.id // .provider // "" | tostring),$rc,$sz]|@csv' "$f" >> "$DIR/manifest.csv"
  done
  sh="$DIR/raw/$n.section_headers.rea.prg.json"; ev=$(jq -r .evidence_id "$sh")
  secs=$(jq -r .normalized_result.stdout "$sh" | awk '$1~/^[0-9]+$/{print $2}')
  hi=$(grep -qx .interp <<<"$secs" && echo yes || echo no)
  hd=$(grep -qx .dynamic <<<"$secs" && echo yes || echo no)
  hs=$(grep -qx .dynsym <<<"$secs" && echo yes || echo no)
  lk=$([ "$hd" = yes ] && echo dynamic || echo static)
  echo "$n,$lk,$hi,$hd,$hs,$hs,rea:inspect-with-objdump/section_headers,$ev" >> "$DIR/linkage.csv"
  # absence is a row, not an empty result (rea: unknown/absent is a value).
  if [ "$hd" = yes ]; then
    objdump -p "$B" | awk -v b="$n" '$1=="NEEDED"{print b","$2",objdump -p (not rea)"}' >> "$DIR/needed.csv"
    nm -D --defined-only "$B" | awk -v b="$n" 'NF==3{print b","$3","$2",nm -D --defined-only (not rea)"}' >> "$DIR/exports.csv"
    grep -q "^$n," "$DIR/exports.csv" || echo "$n,(none),-,nm -D --defined-only: 0 defined dynamic symbols" >> "$DIR/exports.csv"
  else
    echo "$n,(none),rea section_headers: no .dynamic/.interp => statically linked" >> "$DIR/needed.csv"
    echo "$n,(none),-,rea section_headers: no .dynsym => no dynamic symbol table" >> "$DIR/exports.csv"
  fi
  sy="$DIR/raw/$n.symbols.rea.prg.json"; ev=$(jq -r .evidence_id "$sy")
  jq -r .normalized_result.stdout "$sy" | awk -v b="$n" -v ev="$ev" -v dx="$hs" '
    /^[0-9a-f]{16} / { addr=$1; scope=substr($0,18,1); type=substr($0,24,1);
      rest=substr($0,26); split(rest,a," "); sec=a[1]; size=a[2]; name=a[length(a)];
      if (scope==" ") scope="-"; if (type==" ") type="-";
      gsub(/"/,"\"\"",name);
      printf "%s,%s,%s,%s,%s,%s,\"%s\",%s,rea:inspect-with-objdump/symbols,%s\n", b,addr,scope,type,sec,size,name,(dx=="yes"?"maybe":"no"),ev }' >> "$DIR/symbols.csv"
done
bin2md --corpus "$DIR" >/dev/null
