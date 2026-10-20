CC = /usr/bin/gcc
LIBTOOL = /usr/bin/libtool --tag=CC
OBJECTS = $(addprefix part,$(addsuffix .lo,1 2 3 4 5 6 7 8))

.PHONY: check
check: program.exe
	$(LIBTOOL) --mode=execute ./program.exe

part%.lo: $(SOURCE)
	$(LIBTOOL) --mode=compile $(CC) -O2 -Wall -Wextra -Werror -DFUNCTION=part$* -DVALUE=$* -c "$<" -o $@

libwork.la: $(OBJECTS)
	$(LIBTOOL) --mode=link $(CC) -o $@ $(OBJECTS) -rpath "$(CURDIR)/install/lib" -no-undefined

main.o: $(SOURCE)
	$(CC) -O2 -Wall -Wextra -Werror -c "$<" -o $@

program.exe: main.o libwork.la
	$(LIBTOOL) --mode=link $(CC) -o $@ main.o libwork.la
