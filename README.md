Introduction
------------

rmailt is an xmpp transport that makes it possible to send emails the same way
you send instant messages.

rmailt was written primarily as a way to talk to cellphones as an
alternative to SMS, as many phones (blackberry, all japanese phones, etc.) have 
a dedicated email address.

rmailt was created by Eric Butler and is licensed under the GPLv3 or later.
If you have any questions, comments, bug reports, and/or patches, please contact
me via xmpp or email at _eric@extremeboredom.net_.

Installation
------------

Currently rmailt is designed to be installed as a debian package. If you're
compiling from source, run the following command to create a .deb file:

    $ make deb

This will create a .deb package in the parent directory.  Unfortunetly, not all
of the dependencies are currently available as debian packages, so you'll have
to install the following gems:

* xmpp4r
* tmail
* tlsmail
* datamapper
* SyslogLogger
* do_sqlite3

If you can help debianize these, that would be great.

Install the package you created earlier:

	$ sudo dpkg -i ../rmailt_0.1+git20080928-0.deb

Configuring ejabberd
--------------------

Ejabberd needs to be configured for the new transport. Find the _Listened ports_
section and add the following inside the <code>{listen, [</code> array:

    % Mail Transport
    {5349, ejabberd_service, [{host, "mail.xmpp.example.com",
                            [{password, "letmein"}]}]},

Set the port, host (this is the transport's _JID_), and password appropriately
and keep them handy. You'll need to enter these same values into the rmailt
configuration file next.

Configuration rMailt
--------------------

After installing the package, you'll need to configure it. 
Copy /usr/share/doc/rmailt/rmailt.yml.example to /etc/rmailt.yml and edit the 
values. _port_, _jid_, and _secret_ need to match the values in your ejabberd
config.

Configuring Postfix
-------------------

rmailt assumes that any email sent to your transport's hostname 
(eg _*@mail.xmpp.example.com_) will be delivered to a single IMAP account. This 
can be done using the postfix virtual mailbox feature.

For example, if you have an IMAP account called _xmpp_, you would add the 
following to /etc/postfix/vmailbox:

    @mail.xmpp.example.com xmpp/

And the following to /etc/postfix/main.cf:

    virtual_mailbox_base = /var/mail
    virtual_mailbox_maps = hash:/etc/postfix/vmailbox
    virtual_uid_maps = static:65534
    virtual_gid_maps = static:65534

You can read more about this in the man page.

    $ man 8postfix virtual

Usage
-----

Once the transport is successfully connected to your XMPP server, open your
client's service discovery window and look for _SMTP Transport_. Select it and
click _Register_. If you configured an access password in the config file, enter
it here. You only need to register once.

After you are registered, select your client's _Add Contact_ option. The dialog
should have a new option to change the protocol to _smtp_. Select this and enter
the email address you wish to contact.

Any messages sent to this contact will be sent on as emails.
