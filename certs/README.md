Place the SEBI SOCNOC CA certificate here as:

socnoc.crt

The airgapped start script builds a local CA-enabled image from this certificate.

For Keycloak LDAP over LDAPS, place the PEM bundle containing every trusted
Active Directory domain-controller certificate here as:

sebi-ldap-ca-bundle.pem

start-keycloak-ldap.sh validates this bundle and builds the certificate-enabled
Keycloak image automatically before starting the Compose deployment.
