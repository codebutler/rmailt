deb:
	rm -f debian/changelog
	dch --package rmailt --newversion 0.1+git`date +"%Y%m%d"` --create "Automatic package"
	dpkg-buildpackage -rfakeroot

