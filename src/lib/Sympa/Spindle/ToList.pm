# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id$

# Sympa - SYsteme de Multi-Postage Automatique
#
# Copyright (c) 1997, 1998, 1999 Institut Pasteur & Christophe Wolfhugel
# Copyright (c) 1997, 1998, 1999, 2000, 2001, 2002, 2003, 2004, 2005,
# 2006, 2007, 2008, 2009, 2010, 2011 Comite Reseau des Universites
# Copyright (c) 2011, 2012, 2013, 2014, 2015 GIP RENATER
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Sympa::Spindle::ToList;

use strict;
use warnings;
use Time::HiRes qw();

use Sympa;
use Sympa::Bulk;
use Conf;
use Sympa::Log;
use Sympa::Report;
use Sympa::Tools::Data;
use Sympa::Topic;
use Sympa::Tracking;

use base qw(Sympa::Spindle);

my $log = Sympa::Log->instance;

sub _twist {
    my $self    = shift;
    my $message = shift;

    my $list      = $message->{context};
    my $messageid = $message->{message_id};
    my $sender =
           $self->{confirmed_by}
        || $self->{distributed_by}
        || $message->{sender};

    my $numsmtp = _send_msg($message);
    unless (defined $numsmtp) {
        $log->syslog('err', 'Unable to send message %s to list %s',
            $message, $list);
        Sympa::send_notify_to_listmaster(
            $list,
            'mail_intern_error',
            {   error  => '',
                who    => $sender,
                msg_id => $messageid,
            }
        );
        Sympa::send_dsn($list, $message, {}, '5.3.0');
        $log->db_log(
            'robot'        => $list->{'domain'},
            'list'         => $list->{'name'},
            'action'       => 'DoMessage',
            'parameters'   => $message->get_id,
            'target_email' => '',
            'msg_id'       => $messageid,
            'status'       => 'error',
            'error_type'   => 'internal',
            'user_email'   => $sender
        );
        return undef;
    } elsif (not $self->{quiet}) {
        if ($self->{confirmed_by}) {
            Sympa::Report::notice_report_msg('message_confirmed', $sender,
                {'key' => $self->{authkey}, 'message' => $message},
                $list->{'domain'}, $list);
        } elsif ($self->{distributed_by}) {
            Sympa::Report::notice_report_msg('message_distributed', $sender,
                {'key' => $self->{authkey}, 'message' => $message},
                $list->{'domain'}, $list);
        }
    }

    $log->syslog(
        'info',
        'Message %s for %s from %s accepted (%.2f seconds, %d sessions, %d subscribers), message ID=%s, size=%d',
        $message,
        $list,
        $sender,
        Time::HiRes::time() - $self->{start_time},
        $numsmtp,
        $list->get_total,
        $messageid,
        $message->{'size'}
    );

    return 1;
}

# Private subroutines.

# Extract a set of rcpt for which VERP must be use from a rcpt_tab.
# Input  :  percent : the rate of subscribers that must be threaded using VERP
#           xseq    : the message sequence number
#           @rcpt   : a tab of emails
# return :  a tab of recipients for which recipients must be used depending on
#           the message sequence number, this way every subscriber is "VERPed"
#           from time to time input table @rcpt is spliced: recipients for
#           which VERP must be used are extracted from this table
# Old name: List::extract_verp_rcpt(), Sympa::List::_extract_verp_rcpt().
sub _extract_verp_rcpt {
    $log->syslog('debug3', '(%s, %s, %s, %s)', @_);
    my $percent     = shift;
    my $xsequence   = shift;
    my $refrcpt     = shift;
    my $refrcptverp = shift;

    my @result;

    if ($percent ne '0%') {
        my $nbpart;
        if ($percent =~ /^(\d+)\%/) {
            $nbpart = 100 / $1;
        } else {
            $log->syslog('err',
                'Wrong format for parameter: %s. Can\'t process VERP',
                $percent);
            return undef;
        }

        my $modulo = $xsequence % $nbpart;
        my $length = int(scalar(@$refrcpt) / $nbpart) + 1;

        @result = splice @$refrcpt, $length * $modulo, $length;
    }
    foreach my $verprcpt (@$refrcptverp) {
        push @result, $verprcpt;
    }
    return (@result);
}

# Old names: List::send_msg(), (part of) Sympa::List::distribute_msg().
sub _send_msg {
    my $message = shift;

    my $list = $message->{context};

    # Synchronize list members, required if list uses include sources
    # unless sync_include has been performed recently.
    if ($list->has_include_data_sources()) {
        unless (defined $list->on_the_fly_sync_include(use_ttl => 1)) {
            $log->syslog('notice', 'Unable to synchronize list %s', $list);
            #FIXME: Might be better to abort if synchronization failed.
        }
    }

    # Blindly send the message to all users.

    my $total = $list->get_total('nocache');

    unless ($total > 0) {
        $log->syslog('info', 'No subscriber in list %s', $list);
        $list->savestats;
        return 0;
    }

    ## Bounce rate
    my $rate = $list->get_total_bouncing() * 100 / $total;
    if ($rate > $list->{'admin'}{'bounce'}{'warn_rate'}) {
        $list->send_notify_to_owner('bounce_rate', {'rate' => $rate});
        if (100 <= $rate) {
            Sympa::send_notify_to_user($list, 'hundred_percent_error',
                $message->{sender});
            Sympa::send_notify_to_listmaster($list, 'hundred_percent_error',
                {sender => $message->{sender}});
        }
    }

    #save the message before modifying it
    my $nbr_smtp = 0;

    # prepare verp parameter
    my $verp_rate = $list->{'admin'}{'verp_rate'};
    # force VERP if tracking is requested.
    $verp_rate = '100%'
        if Sympa::Tools::Data::smart_eq($message->{shelved}{tracking},
        qr/dsn|mdn/);

    my $tags_to_use;

    # Define messages which can be tagged as first or last according to the
    # VERP rate.
    # If the VERP is 100%, then all the messages are VERP. Don't try to tag
    # not VERP
    # messages as they won't even exist.
    if ($verp_rate eq '0%') {
        $tags_to_use->{'tag_verp'}   = '0';
        $tags_to_use->{'tag_noverp'} = 'z';
    } else {
        $tags_to_use->{'tag_verp'}   = 'z';
        $tags_to_use->{'tag_noverp'} = '0';
    }

    # Separate subscribers depending on user reception option and also if VERP
    # a dicovered some bounce for them.
    # Storing the not empty subscribers' arrays into a hash.
    my $available_recipients = $list->get_recipients_per_mode($message);
    unless ($available_recipients) {
        $log->syslog('info', 'No subscriber for sending msg in list %s',
            $list);
        $list->savestats;
        return 0;
    }

    foreach my $mode (sort keys %$available_recipients) {
        my $new_message = $message->dup;
        unless ($new_message->prepare_message_according_to_mode($mode, $list))
        {
            $log->syslog('err', "Failed to create Message object");
            return undef;
        }

        ## TOPICS
        my @selected_tabrcpt;
        my @possible_verptabrcpt;
        if ($list->is_there_msg_topic) {
            my $topic = Sympa::Topic->load($message);
            my $topic_list = $topic ? $topic->{topic} : '';

            @selected_tabrcpt =
                $list->select_list_members_for_topic($topic_list,
                $available_recipients->{$mode}{'noverp'} || []);
            @possible_verptabrcpt =
                $list->select_list_members_for_topic($topic_list,
                $available_recipients->{$mode}{'verp'} || []);
        } else {
            @selected_tabrcpt =
                @{$available_recipients->{$mode}{'noverp'} || []};
            @possible_verptabrcpt =
                @{$available_recipients->{$mode}{'verp'} || []};
        }

        ## Preparing VERP recipients.
        my @verp_selected_tabrcpt = _extract_verp_rcpt(
            $verp_rate,         $message->{xsequence},
            \@selected_tabrcpt, \@possible_verptabrcpt
        );

        # Prepare non-VERP sending.
        if (@selected_tabrcpt) {
            my $result =
                _mail_message($new_message, \@selected_tabrcpt,
                tag => $tags_to_use->{'tag_noverp'});
            unless (defined $result) {
                $log->syslog(
                    'err',
                    'Could not send message to distribute to list %s (VERP disabled)',
                    $list
                );
                return undef;
            }
            $tags_to_use->{'tag_noverp'} = '0' if $result;
            $nbr_smtp++;

            # Add number and size of messages sent to total in stats file.
            my $numsent = scalar @selected_tabrcpt;
            my $bytes   = length $new_message->as_string;
            $list->{'stats'}->[1] += $numsent;
            $list->{'stats'}->[2] += $bytes;
            $list->{'stats'}->[3] += $bytes * $numsent;
        } else {
            $log->syslog(
                'notice',
                'No non VERP subscribers left to distribute message to list %s',
                $list
            );
        }

        $new_message->{shelved}{tracking} ||= 'verp';

        if ($new_message->{shelved}{tracking} =~ /dsn|mdn/) {
            my $tracking = Sympa::Tracking->new($list);

            $tracking->register($new_message, [@verp_selected_tabrcpt],
                'reception_option' => $mode);
        }

        # Ignore those reception option where mail must not ne sent.
        next
            if $mode eq 'digest'
                or $mode eq 'digestplain'
                or $mode eq 'summary'
                or $mode eq 'nomail';

        ## prepare VERP sending.
        if (@verp_selected_tabrcpt) {
            my $result =
                _mail_message($new_message, \@verp_selected_tabrcpt,
                tag => $tags_to_use->{'tag_verp'});
            unless (defined $result) {
                $log->syslog(
                    'err',
                    'Could not send message to distribute to list %s (VERP enabled)',
                    $list
                );
                return undef;
            }
            $tags_to_use->{'tag_verp'} = '0' if $result;
            $nbr_smtp++;

            # Add number and size of messages sent to total in stats file.
            my $numsent = scalar @verp_selected_tabrcpt;
            my $bytes   = length $new_message->as_string;
            $list->{'stats'}->[1] += $numsent;
            $list->{'stats'}->[2] += $bytes;
            $list->{'stats'}->[3] += $bytes * $numsent;
        } else {
            $log->syslog('notice',
                'No VERP subscribers left to distribute message to list %s',
                $list);
        }
    }

    #log in stat_table to make statistics...
    unless ($message->{sender} =~ /($Conf::Conf{'email'})\@/) {
        #ignore messages sent by robot
        unless ($message->{sender} =~ /($list->{name})-request/) {
            #ignore messages of requests
            $log->add_stat(
                'robot'     => $list->{'domain'},
                'list'      => $list->{'name'},
                'operation' => 'send_mail',
                'parameter' => $message->{size},
                'mail'      => $message->{sender},
            );
        }
    }
    $list->savestats;
    return $nbr_smtp;
}


# Distribute a message to a list, shelving encryption if needed.
#
# IN : -$message(+) : ref(Sympa::Message)
#      -\@rcpt(+) : recipients
# OUT : -$numsmtp : number of sendmail process | undef
#
# Old name: Sympa::Mail::mail_message(), Sympa::List::_mail_message().
sub _mail_message {
    $log->syslog('debug2', '(%s, %s, %s => %s)', @_);
    my $message = shift;
    my $rcpt    = shift;
    my %params  = @_;

    my $tag = $params{tag};

    my $list = $message->{context};

    # Shelve DMARC protection, unless anonymization feature is enabled.
    $message->{shelved}{dmarc_protect} = 1
        if $list->{'admin'}{'dmarc_protection'}
            and $list->{'admin'}{'dmarc_protection'}{'mode'}
            and not $list->{'admin'}{'anonymous_sender'};

    # Shelve personalization.
    $message->{shelved}{merge} = 1
        if Sympa::Tools::Data::smart_eq($list->{'admin'}{'merge_feature'},
        'on');
    # Shelve re-encryption with S/MIME.
    $message->{shelved}{smime_encrypt} = 1
        if $message->{'smime_crypted'};

    # if not specified, delivery time is right now (used for sympa messages
    # etc.)
    my $delivery_date = $list->get_next_delivery_date;
    $message->{'date'} = $delivery_date if defined $delivery_date;

    # Overwrite original envelope sender.  It is REQUIRED for delivery.
    $message->{envelope_sender} = $list->get_list_address('return_path');

    return Sympa::Bulk->new->store($message, $rcpt, tag => $tag)
        || undef;
}

1;
__END__

=encoding utf-8

=head1 NAME

Sympa::Spindle::ToList - Process to distribute messages to list members

=head1 DESCRIPTION

TBD.

=head1 SEE ALSO

L<Sympa::Bulk>,
L<Sympa::Message>,
L<Sympa::Spindle>, L<Sympa::Spindle::DistributeMessage>,
L<Sympa::Topic>, L<Sympa::Tracking>.

=head1 HISTORY

L<Sympa::Spindle::ToList> appeared on Sympa 6.2.13.

=cut