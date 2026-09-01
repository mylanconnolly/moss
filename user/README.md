# user/

Userspace lands in Phase 3+: root task, init service, runtime library,
services, and drivers. Every process here starts from a blank address space
and an explicit capability manifest — there is no ambient authority to
inherit.
