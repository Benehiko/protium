# Wine patches

The patches `protium build` applies to Wine's source before `configure`, in
file-name order. Each one begins with its reason; `src/recipe.zig` lists them,
and `build.zig` embeds them in the protium binary.

## Licence

**LGPL-2.1-or-later**, not Apache 2.0.

Each patch changes files in Wine, which is licensed under the GNU Lesser
General Public License, version 2.1 or later, and quotes Wine's own lines as
context. The patches are offered under the same terms as the files they
change, so they can go upstream or into anyone's Wine without a licence
question. The licence text is in [`licenses/LGPL-2.1.txt`](../licenses/LGPL-2.1.txt).

Copyright in the changes: Alano Terblanche. Copyright in the quoted context:
the Wine project authors.

The rest of this repository, including the code that embeds and applies these
files, is Apache 2.0 ([`LICENSE`](../LICENSE)). Carrying a patch as data does
not bring protium's code under the LGPL, and does not bring the patch under
Apache.
