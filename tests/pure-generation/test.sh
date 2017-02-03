#!/bin/bash

echo "BLANK"
../../eff.native --pure --compile blank.eff
echo "INTERPRETER"
echo "  DIVERGES"
# ../../eff.native --pure --compile interp.eff
echo "LOOP"
../../eff.native --pure --compile loop.eff
echo "LOOP EFFECTS"
../../eff.native --pure --compile loopEffect.eff
echo "PARSER"
echo "  DIVERGES"
# ../../eff.native --pure --compile parser.eff
echo "QUEENS"
../../eff.native --pure --compile queens.eff