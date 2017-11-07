#!/bin/bash

if [[ ! -z $CURRENT_USER ]]; then
	USER=$CURRENT_USER
fi
MAIL_DIR="/var/emailsdb"
KEYS_DIR="/var/keys"
MAIL_USER_DIR="$MAIL_DIR/$USER"
TMP_FILE=$(tempfile 2>/dev/null) || TMP_FILE=/tmp/test$$
RECIEPIANTS=()
SUBJECT=""
MSG_BODY=""

function user_mail_dir_exists {
	if [[ -d "$MAIL_DIR/$1" ]]; then
		return 0
	fi
	return 1
}

function create_user_mail_dir {
	mkdir -p "$MAIL_DIR/$1/Inbox"
	mkdir -p "$MAIL_DIR/$1/Sent"
	mkdir -p "$MAIL_DIR/$1/Attachments"
}

function setup {
	# create the initial mail dir
	if [[ ! -d $MAIL_DIR ]]; then
		mkdir -p $MAIL_DIR
		chmod 700 $MAIL_DIR
	fi

	# create the user dir
	if [[ ! -d $MAIL_USER_DIR ]]; then
		create_user_mail_dir $USER
	fi
	# create keys dir and set the sticky bit
	if [[ ! -d $KEYS_DIR ]]; then
		mkdir -p $KEYS_DIR
		chgrp email $KEYS_DIR
		chmod 1770 $KEYS_DIR
	fi
	#import new keys
	gpg --homedir "/root/.gnupg" --import /var/keys/*.key > /dev/null
}

function get_user_list {
	awk -F: '/\/home/ && ($3 >= 1000) {printf "%s ",$1}' /etc/passwd
}


function menu {
	dialog 	--cancel-label "Quit" \
			--ok-label "Choose" \
			--backtitle "Messages App" \
			--menu "Choose an option" \
			10 40 10 \
			1 "Send Message" 2 "Inbox" 3 "Sent"  2> $TMP_FILE
	ret=$(cat $TMP_FILE)
	if [[ -z $ret ]]; then
		exit 0
	fi
	case $ret in
		1)
			select_receipient
			;;
		2)
			inbox
			;;
		3)
			sent
			;;
		*)
			exit 0;
	esac
}
function select_receipient {
	users_list=()
	options=()
	i=0
	for user in $(get_user_list); do
		users_list+=($user)
		options+="$i $user  off "
		let i=i+1
	done
	users_list+=("root")
	options+="$i root  off "
	dialog 	--ok-label "Ok" \
			--cancel-label "Back" \
			--backtitle "Messages App" \
			--no-tags \
			--checklist "Select receipients" \
			15 40 4 \
			${options[@]}  2> $TMP_FILE
	ret=$(cat $TMP_FILE)
	if [[ -z $ret ]]; then
		menu
	else
		for i in $(cat $TMP_FILE); do
			RECIEPIANTS+=(${users_list[$i]})
		done
		subject_message
	fi
}
function subject_message {
	dialog 	--cancel-label "Back" \
			--ok-label "Next" \
			--backtitle "Messages App" \
			--inputbox "Subject"  \
			10 40 2> $TMP_FILE
	ret=$(cat $TMP_FILE)
	if [[ -z $ret ]]; then
		select_receipient
	else
		SUBJECT=$(cat $TMP_FILE)
		text_message
	fi
	

}
function text_message {
	if [[ -z $EDITOR ]]; then
		EDITOR=nano
	fi
	echo $MSG_BODY > $TMP_FILE
	$EDITOR $TMP_FILE
	MSG_BODY="$(cat $TMP_FILE)"
	dialog 	--no-label "Edit" \
			--ok-label "Ok" \
			--backtitle "Messages App" \
			--title "You typed this Message"\
			--yesno "$MSG_BODY"  \
			10 40 2> $TMP_FILE
	ret=$?
	if [[ $ret -eq 1 ]]; then
		text_message
	fi
	dialog 	--no-label "No" \
			--ok-label "Ok" \
			--backtitle "Messages App" \
			--title "Do you want to encrypt this Message"\
			--yesno "$MSG_BODY"  \
			10 40 2> $TMP_FILE
	encrypt=$?
	i=0
	lengh=${#RECIEPIANTS}
	for user in ${RECIEPIANTS[@]}; do
		user_mail_dir_exists $user || create_user_mail_dir $user
		msg="$(date)\n$USER\n$user\n$SUBJECT\n$MSG_BODY"
		timestamp=$(date +%s)
		MSG_FILE=$(tempfile 2> /dev/null)
		echo -e $msg > $MSG_FILE
		subject=$(echo $SUBJECT | tr ' ' '-')
		if [[ $encrypt -eq 1 ]]; then
			msg_file="$MAIL_DIR/$user/Inbox/$timestamp-$subject.msg"
			cp -f $MSG_FILE "$msg_file"
		else
			msg_file_enc="$MAIL_DIR/$user/Inbox/$timestamp-$subject.msg.enc"
			dialog 	--cancel-label "Cancel" \
					--ok-label "Next" \
					--backtitle "Messages App" \
					--inputbox "Email Adress of the destination"  \
					10 40 2> $TMP_FILE
			ret=$(cat $TMP_FILE)
			if [[ -z $ret ]]; then
				menu
			else
				gpg -k --homedir "/root/.gnupg" $ret > /dev/null
				if [[ $? -eq 0 ]]; then
					yes | gpg -r $ret --homedir "/root/.gnupg"  -o "$msg_file_enc" --encrypt $MSG_FILE
				else
					dialog 	--ok-label "Ok" \
							--backtitle "Messages App" \
							--msgbox "The destination don't have a keys, to generate on type 'gpg --key-gen ; gpg --export <email> > /var/keys/<user>.key'"  \
							10 40
					menu
				fi
			fi	
		fi
		cp -f "$MSG_FILE" "$MAIL_USER_DIR/Sent/$timestamp-$subject.msg"
		let i=i+$((100/$lengh))
		echo $i | dialog --title "Sending" --gauge "Sending messages" 10 70 0
		sleep 1
	done 
	dialog 	--ok-label "Ok" \
			--backtitle "Messages App" \
			--msgbox "Your Message has been sent succesfully"  \
			10 40
	menu
}

function inbox {
	user_mail_dir_exists $USER || create_user_mail_dir $USER
	messages=()
	options=()
	files=()
	i=0
	for msg in $(ls "$MAIL_USER_DIR/Inbox/" | sort -r ); do
		if [[ $msg -eq *.enc ]]; then
			file_dec=$(tempfile 2> /dev/null)
			gpg --homedir "$USER/.gnupg" -d $msg > $file_dec
			files+=($file_dec)
			msg_date=$(head -n3 "$MAIL_USER_DIR/Inbox/$msg")
			from=$(head -n4 "$MAIL_USER_DIR/Inbox/$msg"| tail -n1 )
			title=$(head -n6 "$MAIL_USER_DIR/Inbox/$msg"| tail -n1 )
			message="$title - from $from on $msg_date"
		else
			files+=("$MAIL_USER_DIR/Inbox/$msg")
			msg_date=$(head -n1 "$MAIL_USER_DIR/Inbox/$msg")
			from=$(head -n2 "$MAIL_USER_DIR/Inbox/$msg"| tail -n1 )
			title=$(head -n4 "$MAIL_USER_DIR/Inbox/$msg"| tail -n1 )
			message="$title - from $from on $msg_date"	
		fi
		options+=($i "$message")
		let i=i+1
	done
	if [[ ${#options} -lt 1 ]]; then
		dialog 	--ok-label "Ok" \
			--backtitle "Messages App" \
			--msgbox "Your Inbox is empty"  \
			10 40
		menu
	fi
	dialog 	--cancel-label "Back" \
			--ok-label "Choose" \
			--backtitle "Messages App" \
			--menu "Choose a message" \
			15 80 10 \
			"${options[@]}"  2> $TMP_FILE
	ret=$(cat $TMP_FILE)
	if [[ -z $ret  ]]; then
		menu
		if [[ -f $file_dec ]]; then
			rm -f $file_dec
		fi
	else
		f="${files[$ret]}"
		text_body="$(tail -n +5 $f)"
		dialog --no-label "Delete"	\
			--ok-label "Back" \
			--backtitle "Messages App" \
			--yesno "$text_body" \
			10 40 
		ret=$?
		if [[ $ret -eq 1 ]]; then
			rm -rf $f
		fi
		inbox
		if [[ -f $file_dec ]]; then
			rm -f $file_dec
		fi
	fi
	if [[ -f $file_dec ]]; then
		rm -f $file_dec
	fi
}


function sent {
	user_mail_dir_exists $USER || create_user_mail_dir $USER
	messages=()
	options=()
	files=()
	i=0
	for msg in $(ls "$MAIL_USER_DIR/Sent/" | sort -r ); do
		files+=("$MAIL_USER_DIR/Sent/$msg")
		msg_date=$(head -n1 "$MAIL_USER_DIR/Sent/$msg")
		to=$(head -n3 "$MAIL_USER_DIR/Sent/$msg"| tail -n1 )
		title=$(head -n4 "$MAIL_USER_DIR/Sent/$msg"| tail -n1 )
		message="$title - to $to on $msg_date"
		options+=($i "$message")
		let i=i+1
	done
	if [[ ${#options} -lt 1 ]]; then
		dialog 	--ok-label "Ok" \
			--backtitle "Messages App" \
			--msgbox "Your sent box is empty"  \
			10 40
		menu
	fi
	dialog 	--cancel-label "Back" \
			--ok-label "Choose" \
			--backtitle "Messages App" \
			--menu "Choose a message" \
			15 80 10 \
			"${options[@]}"  2> $TMP_FILE
	ret=$(cat $TMP_FILE)
	if [[ -z $ret  ]]; then
		menu
	else
		f="${files[$ret]}"
		text_body="$(tail -n +5 $f)"
		dialog --no-label "Delete"	\
			--ok-label "Back" \
			--backtitle "Messages App" \
			--yesno "$text_body" \
			10 40 
		ret=$?
		if [[ $ret -eq 1 ]]; then
			rm -rf $f
		fi
		sent
	fi
}

setup
menu









