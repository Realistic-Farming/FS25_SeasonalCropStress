# NPCFavor host fixture for the SCS bench

A verbatim copy of the FS25_NPCFavor host files the RSF-F357 SCS caller pairs with, at
FS25_NPCFavor development a1caebf7b326addf894e5becdd051b1ee33f3bad (the merge of PR #115, RSF-F357 PR 1 of 4).
The SCS spec RSF-F357-scs_caller_spec_test.lua boots this real host (NPCSystem.new,
onMissionLoaded, the first-frame updater) and claims through it, so the caller is driven
against the real claim, getter and roster load rather than a stand-in. Test fixture only:
tools/ is excluded from the shipped zip. Refresh by copying the same files from the host
commit named here and updating this line.
