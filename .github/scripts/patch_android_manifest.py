import sys

path = sys.argv[1]
with open(path) as f:
    xml = f.read()

m_start = xml.index("<manifest")
m_close = xml.index(">", m_start)
xml = (
    xml[: m_close + 1]
    + "\n    <uses-permission android:name='android.permission.INTERNET' />"
    + "\n    <uses-permission android:name='android.permission.CAMERA' />"
    + xml[m_close + 1 :]
)

a_start = xml.index("<application")
a_close = xml.index(">", a_start)
xml = (
    xml[:a_start]
    + "<application android:usesCleartextTraffic='true'"
    + xml[a_start + len("<application") : a_close + 1]
    + xml[a_close + 1 :]
)

with open(path, "w") as f:
    f.write(xml)
