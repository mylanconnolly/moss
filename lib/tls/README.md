# Test material for TLS

A root and a server certificate the tests and the gate use — and
nothing else trusts. `moss-test-ca.pem` is packed into the boot archive
as `tls/moss-test-ca.pem` and given to the net drill's script as its
only trust root; `moss-test-server.pem` / `.key` are what the runner's
`openssl s_server` presents for `tls.moss.test`; `lib/tls.zig`'s host
tests verify the one by the other. Both keys are P-256, both
certificates good for a hundred years from 2026-09-05. To make them
again:

```sh
openssl ecparam -name prime256v1 -genkey -noout -out moss-test-ca.key
openssl req -x509 -new -key moss-test-ca.key -sha256 -days 36500 \
  -subj "/CN=moss test root" -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" -out moss-test-ca.pem
openssl ecparam -name prime256v1 -genkey -noout -out moss-test-server.key
openssl req -new -key moss-test-server.key -subj "/CN=tls.moss.test" -out server.csr
printf "subjectAltName=DNS:tls.moss.test\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\n" > server.ext
openssl x509 -req -in server.csr -CA moss-test-ca.pem -CAkey moss-test-ca.key \
  -CAcreateserial -days 36500 -sha256 -extfile server.ext -out moss-test-server.pem
rm server.csr server.ext moss-test-ca.srl
```

The system's real trust roots are elsewhere: `boot/tls/roots.pem`, the
Mozilla root store as curl publishes it (https://curl.se/ca/cacert.pem;
the date is in its header), packed as `tls/roots.pem`.
