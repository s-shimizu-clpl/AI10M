# x86_64 version of the guest in main.rs (same logic as the AArch64 one).
# Syscall numbers come from main.rs as `const` operands (libc::SYS_*).
.text
.globl enter_guest, http_guest
.p2align 4
# enter_guest(task: rdi, argv: rsi, gate: rdx, io: rcx) -> eax
# Frame after prologue (rsp 16-byte aligned):
#   [rsp+0..16) sockaddr_in scratch, [rsp+16] io, [rsp+24] argv, [rsp+32] pad
enter_guest:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub  rsp, 40
    mov  [rsp + 16], rcx       # Syscall context
    mov  [rsp + 24], rsi       # argv
    mov  r12, rdi              # Current Task
    mov  r13, rdx              # Address of the host gate pointer
    mov  ebx, [r12 + 8]        # fd_server
    mov  ebp, [r12 + 12]       # fd_client
    jmp  qword ptr [r12]

http_guest:
    mov  edi, 2                # AF_INET
    mov  esi, 1                # SOCK_STREAM
    xor  edx, edx
    call syscall_socket
    mov  ebx, eax              # Listener fd
    mov  rax, [rsp + 24]
    mov  rdi, [rax + 8]        # argv[1]
    call inet_addr@PLT
    mov  dword ptr [rsp], 0x901f0002 # AF_INET, port 8080 in network byte order
    mov  dword ptr [rsp + 4], eax
    mov  qword ptr [rsp + 8], 0

    movsxd rdi, ebx
    mov  rsi, rsp
    mov  edx, 16               # sizeof(sockaddr_in)
    call syscall_bind

    movsxd rdi, ebx
    mov  esi, 128              # Backlog
    call syscall_listen
    test rax, rax
    mov  eax, 1
    js   guest_return

# Each iteration starts by waiting for a client.
accept_client:
    movsxd rdi, ebx
    xor  esi, esi
    xor  edx, edx
    call syscall_accept
    cmp  rax, -11              # -EAGAIN: retry accept when a client is ready.
    je   wait_accept
    test eax, eax
    js   accept_failed
    mov  ebp, eax              # Client fd

    # Loop body. Read the request and reply if data arrived.
read_client:
    mov  edi, ebp
    xor  esi, esi
    mov  edx, 4096
    mov  ecx, 32               # MSG_TRUNC
    xor  r8d, r8d
    xor  r9d, r9d
    call syscall_recvfrom
    cmp  rax, -11              # -EAGAIN: retry recv when data or EOF arrives.
    je   wait_read
    cmp  rax, 1
    jl   close_client

    mov  edi, ebp
    lea  rsi, [rip + http_reply]
    mov  edx, 40
    mov  ecx, 16384            # MSG_NOSIGNAL
    xor  r8d, r8d
    xor  r9d, r9d
    call syscall_sendto

close_client:
    mov  edi, ebp
    call syscall_close
    mov  ebp, -1
    jmp  accept_client         # End of the loop body. Wait for the next client.

wait_accept:
    lea  rax, [rip + accept_client]
    jmp  yield_guest

wait_read:
    lea  rax, [rip + read_client]
    jmp  yield_guest

accept_failed:
    xor  eax, eax
guest_return:
    mov  qword ptr [r12], 0    # A zero PC marks a finished task.
    jmp  resume_main

yield_guest:
    mov  [r12], rax            # Resume at the saved guest address.
    xor  eax, eax
resume_main:
    mov  [r12 + 8], ebx
    mov  [r12 + 12], ebp
    add  rsp, 40
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rbp
    pop  rbx
    ret

syscall_socket:
    mov  eax, {sys_socket}
    jmp  call_host
syscall_bind:
    mov  eax, {sys_bind}
    jmp  call_host
syscall_listen:
    mov  eax, {sys_listen}
    jmp  call_host
syscall_accept:
    mov  eax, {sys_accept}
    jmp  call_host
syscall_recvfrom:
    mov  eax, {sys_recvfrom}
    jmp  call_host
syscall_sendto:
    mov  eax, {sys_sendto}
    jmp  call_host
syscall_close:
    mov  eax, {sys_close}
    jmp  call_host

# Arguments 0..5 are already in rdi..r9. SysV passes the 7th (syscall number)
# and 8th (guest syscall context) on the stack, 16-byte aligned at the call.
call_host:
    mov  r10, [rsp + 24]       # Guest syscall context (frame slot +16, past our return address)
    sub  rsp, 8
    push r10
    push rax
    call qword ptr [r13]
    add  rsp, 24
    ret

http_reply:
    .ascii "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok"
