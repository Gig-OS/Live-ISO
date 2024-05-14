#!/bin/bash

# copy extra staff for fresh squashfs
rsync -rl --copy-unsafe-links "${WORKDIR}"/include-squashfs.after/* "${WORKDIR}/squashfs/"
