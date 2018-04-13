use v5.24.0;
package Synergy::Reactor::LiquidPlanner;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures lexical_subs);
use namespace::clean;
use List::Util qw(first);
use Net::Async::HTTP;
use JSON 2 ();
use Time::Duration;
use Synergy::Logger '$Logger';
use Synergy::Util qw(parse_time_hunk pick_one);
use DateTime;
use utf8;

my $JSON = JSON->new;

my $ERR_NO_LP = "You don't seem to be a LiquidPlanner-enabled user.";
my $WKSP_ID = 14822;
my $LP_BASE = "https://app.liquidplanner.com/api/workspaces/$WKSP_ID";
my $LINK_BASE = "https://app.liquidplanner.com/space/$WKSP_ID/projects/show/";
my $CONFIG;  # XXX use real config

$CONFIG = {
  liquidplanner => {
    workspace => '14822',
    package => {
      inbox => '6268529',
      urgent => '11388082',
      recurring => '27659967',
    },
    project => {
      comms =>  '39452359',
      cyrus =>  '38805977',
      fastmail =>  '36611517',
      listbox =>  '274080',
      plumbing =>  '39452373',
      pobox =>  '274077',
      topicbox =>  '27495364',
    },
  },
};

my %KNOWN = (
  timer     => \&_handle_timer,
  task      => \&_handle_task,
  tasks     => \&_handle_tasks,
  inbox     => \&_handle_inbox,
  urgent    => \&_handle_urgent,
  recurring => \&_handle_recurring,
  '++'      => \&_handle_plus_plus,
  good      => \&_handle_good,
  gruß      => \&_handle_good,
  expand    => \&_handle_expand,
  chill     => \&_handle_chill,
  shows     => \&_handle_shows,
  "show's"  => \&_handle_shows,
  showtime  => \&_handle_showtime,
  commit    => \&_handle_commit,
  abort     => \&_handle_abort,
  start     => \&_handle_start,
  stop      => \&_handle_stop,
  resume    => \&_handle_resume,
  restart   => \&_handle_resume,
  reset     => \&_handle_reset,
  done      => \&_handle_done,
  spent     => \&_handle_spent,
  projects  => \&_handle_projects,
);

sub listener_specs {
  return (
    {
      name      => "you're-back",
      method    => 'see_if_back',
      predicate => sub { 1 },
    },
    {
      name      => "liquid planner",
      method    => "dispatch_event",
      exclusive => 1,
      predicate => sub ($self, $event) {
        return unless $event->type eq 'message';
        return unless $event->was_targeted;

        my ($what) = $event->text =~ /^([^\s]+)\s?/;
        $what &&= lc $what;

        return 1 if $KNOWN{$what};
        return 1 if $what =~ /^g'day/;    # stupid, but effective
        return 1 if $what =~ /^goo+d/;    # Adrian Cronauer
        return 1 if $what =~ /^done,/;    # ugh
        return;
      }
    },
    {
      name      => "lp-mention-in-passing",
      method    => "provide_lp_link",
      predicate => sub { 1 },

    },
    {
      name      => "last-thing-said",
      method    => 'record_utterance',
      predicate => sub { 1 },
    },
  );
}

sub dispatch_event ($self, $event, $rch) {
  unless ($event->from_user) {
    $rch->reply("Sorry, I don't know who you are.");
    $event->mark_handled;
    return 1;
  }

  # existing hacks for silly greetings
  my $text = $event->text;
  $text = "good day_au" if $text =~ /\A\s*g'day(?:,?\s+mate)?[1!.?]*\z/i;
  $text = "good day_de" if $text =~ /\Agruß gott[1!.]?\z/i;
  $text =~ s/\Ago{3,}d(?=\s)/good/;
  $text =~  s/^done, /done /;   # ugh

  my ($what, $rest) = $text =~ /^([^\s]+)\s*(.*)/;
  $what &&= lc $what;

  # It's not handled yet, but it will have been by the time we return!
  $event->mark_handled;

  # we can be polite even to non-lp-enabled users
  return $self->_handle_good($event, $rch, $rest) if $what eq 'good';

  unless ($event->from_user->lp_auth_header) {
    $rch->reply($ERR_NO_LP);
    return 1;
  }

  return $KNOWN{$what}->($self, $event, $rch, $rest)
}

sub provide_lp_link ($self, $event, $rch) {
  my $user = $event->from_user;
  return unless $user && $user->lp_auth_header;

  if (my ($task_id) = $event->text =~ /LP([0-9]{8})/) {
    my $task_res = $self->http_get_for_user($user, "$LP_BASE/tasks/$task_id");
    return unless $task_res->is_success;

    my $task = $JSON->decode($task_res->decoded_content);
    my $name = $task->{name};
    $rch->reply("LP$task_id: $task->{name} ($LINK_BASE$task_id)");
    $event->mark_handled if $event->was_targeted;   # do better than bort
  }
}


has user_timers => (
  is               => 'ro',
  isa              => 'HashRef',
  traits           => [ 'Hash' ],
  lazy             => 1,
  handles          => {
    _timer_for_user     => 'get',
    _add_timer_for_user => 'set',
  },

  default => sub { {} },
);

sub timer_for_user ($self, $user) {
  return unless $user->has_lp_token;

  my $timer = $self->_timer_for_user($user->username);
  return $timer if $timer;

  $timer = Synergy::Timer->new({
    time_zone      => $user->time_zone,
    business_hours => $user->business_hours,
  });

  $self->_add_timer_for_user($user, $timer);

  return $timer;
}

has primary_nag_channel_name => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has aggressive_nag_channel_name => (
  is => 'ro',
  isa => 'Str',
  default => 'twilio',
);

has last_utterances => (
  isa       => 'HashRef',
  init_arg  => undef,
  default   => sub {  {}  },
  traits    => [ 'Hash' ],
  handles   => {
    set_last_utterance => 'set',
    get_last_utterance => 'get',
  },
);

sub record_utterance ($self, $event, $rch) {
  # We're not going to support "++ that" by people who are not users.
  return unless $event->from_user;

  my $key = join qq{$;}, $event->from_channel->name, $event->from_address;

  $self->set_last_utterance($key, $event->text);
  return;
}

sub see_if_back ($self, $event, $rch) {
  # We're not going to support "++ that" by people who are not users.
  return unless $event->from_user;

  my $timer = $event->from_user->timer || return;

  if ($timer->chill_until_active
    and $event->text !~ /\bzzz\b/i
  ) {
    $timer->chill_until_active(0);
    $timer->clear_chilltill;
    $rch->reply("You're back!  No longer chilling.")
      if $timer->is_business_hours;
  }
}

has projects => (
  isa => 'HashRef',
  traits => [ 'Hash' ],
  handles => {
    project_ids   => 'values',
    projects      => 'keys',
    project_named => 'get',
    project_pairs => 'kv',
  },
  lazy => 1,
  default => sub ($self) {
    $self->get_project_nicknames;
  },
  writer    => '_set_projects',
);

sub start ($self) {
  $self->projects;

  my $timer = IO::Async::Timer::Periodic->new(
    interval => 300,
    on_tick  => sub ($timer, @arg) { $self->nag($timer); },
  );

  $self->hub->loop->add($timer);

  $timer->start;
}

sub nag ($self, $timer, @) {
  $Logger->log("considering nagging");

  USER: for my $user ($self->hub->user_directory->users) {
    next USER unless my $sy_timer = $user->timer;

    next USER unless $user->should_nag;

    my $username = $user->username;

    my $last_nag = $sy_timer->last_relevant_nag;
    my $lp_timer = $self->lp_timer_for_user($user);

    if ($lp_timer && $lp_timer == -1) {
      $Logger->log("$username: error retrieving timer");
      next USER;
    }

    # Record the last time we saw a timer
    if ($lp_timer) {
      $sy_timer->last_saw_timer(time);
    }

    { # Timer running too long!
      if ($lp_timer && $lp_timer->{running_time} > 3) {
        if ($last_nag && time - $last_nag->{time} < 900) {
          $Logger->log("$username: Won't nag, nagged within the last 15min.");
          next USER;
        }

        my $msg = "Your timer has been running for "
                . concise(duration($lp_timer->{running_time} * 3600))
                . ".  Maybe you should commit your work.";

        my $friendly = $self->hub->channel_named($self->primary_nag_channel_name);
        $friendly->send_message_to_user($user, $msg);

        if ($user) {
          my $aggressive = $self->hub->channel_named($self->aggressive_nag_channel_name);
          $aggressive->send_message_to_user($user, $msg);
        }

        $sy_timer->last_nag({ time => time, level => 0 });
        next USER;
      }
    }

    if ($sy_timer->is_showtime) {
      if ($lp_timer) {
        $Logger->log("$username: We're good: there's a timer.");

        $sy_timer->clear_last_nag;
        next USER;
      }

      my $level = 0;
      if ($last_nag) {
        if (time - $last_nag->{time} < 900) {
          $Logger->log("$username: Won't nag, nagged within the last 15min.");
          next USER;
        }
        $level = $last_nag->{level} + 1;
      }

      # Have we seen a timer recently? Give them a grace period
      if (
           $sy_timer->last_saw_timer
        && $sy_timer->last_saw_timer > time - 900
      ) {
        $Logger->log([
          "not nagging %s, they only recently disabled a timer",
          $username,
        ]);
        next USER;
      }

      my $still = $level == 0 ? '' : ' still';
      my $msg   = "Your LiquidPlanner timer$still isn't running";
      my $friendly = $self->hub->channel_named($self->primary_nag_channel_name);
      $friendly->send_message_to_user($user, $msg);
      if ($level >= 2) {
        my $aggressive = $self->hub->channel_named($self->aggressive_nag_channel_name);
        $aggressive->send_message_to_user($user, $msg);
      }
      $sy_timer->last_nag({ time => time, level => $level });
    }
  }
}

sub get_project_nicknames {
  my ($self) = @_;

  my $query = "/projects?filter[]=custom_field:Nickname is_set&filter[]=is_done is false";
  my $res = $self->http_get_for_master("$LP_BASE$query");
  return {} unless $res && $res->is_success;

  my %project_dict;

  my @projects = @{ $JSON->decode( $res->decoded_content ) };
  for my $project (@projects) {
    # Impossible, right?
    next unless my $nick = $project->{custom_field_values}{Nickname};

    # We'll deal with conflicts later. -- rjbs, 2018-01-22
    $project_dict{ lc $nick } //= [];
    push $project_dict{ lc $nick }->@*, {
      id        => $project->{id},
      nickname  => $nick,
      name      => $project->{name},
    };
  }

  return \%project_dict;
}

sub http_get_for_user ($self, $user, @arg) {
  return $self->hub->http_get(@arg,
    Authorization => $user->lp_auth_header,
  );
}

sub http_post_for_user ($self, $user, @arg) {
  return $self->hub->http_post(@arg,
    Authorization => $user->lp_auth_header,
  );
}

sub http_get_for_master ($self, @arg) {
  my ($master) = $self->hub->user_directory->master_users;
  unless ($master) {
    $Logger->log("No master users configured");
    return;
  }

  $self->http_get_for_user($master, @arg);
}

sub _handle_timer ($self, $event, $rch, $text) {
  my $user = $event->from_user;

  return $rch->reply($ERR_NO_LP)
    unless $user && $user->lp_auth_header;

  my $res = $self->http_get_for_user($user, "$LP_BASE/my_timers");

  unless ($res->is_success) {
    $Logger->log("failed to get timer: " . $res->as_string);

    return $rch->reply("I couldn't get your timer. Sorry!");
  }

  my @timers = grep {; $_->{running} }
               @{ $JSON->decode( $res->decoded_content ) };

  my $sy_timer = $user->timer;

  unless (@timers) {
    my $nag = $sy_timer->last_relevant_nag;
    my $msg;
    if (! $nag) {
      $msg = "You don't have a running timer.";
    } elsif ($nag->{level} == 0) {
      $msg = "Like I said, you don't have a running timer.";
    } else {
      $msg = "Like I keep telling you, you don't have a running timer!";
    }

    return $rch->reply($msg);
  }

  if (@timers > 1) {
    $rch->reply(
      "Woah.  LiquidPlanner says you have more than one active timer!",
    );
  }

  my $timer = $timers[0];
  my $time = concise( duration( $timer->{running_time} * 3600 ) );
  my $task_res = $self->http_get_for_user($user, "$LP_BASE/tasks/$timer->{item_id}");

  my $name = $task_res->is_success
           ? $JSON->decode($task_res->decoded_content)->{name}
           : '??';

  my $url = sprintf "$LINK_BASE/%s", $timer->{item_id};

  return $rch->reply(
    "Your timer has been running for $time, work on: $name <$url>",
  );
}

sub _handle_task ($self, $event, $rch, $text) {
  # because of "new task for...";
  my $what = $text =~ s/\Atask\s+//r;

  my ($target, $name) = $what =~ /\s*for\s+@?(.+?)\s*:\s+(.+)\z/;

  return -1 unless $target and $name;

  my @target_names = split /(?:\s*,\s*|\s+and\s+)/, $target;
  my (@owners, @no_lp, @unknown);
  my %seen;

  my %project_id;
  for my $name (@target_names) {
    my $target = $self->resolve_name($name, $event->from_user->username);

    next if $target && $seen{ $target->username }++;

    my $owner_id = $target ? $target->lp_id : undef;

    # Sadly, the following line is not valid:
    # push(($owner_id ? @owner_ids : @unknown), $owner_id);
    if ($owner_id) {
      push @owners, $target;

      # XXX - From real config! --alh, 2018-03-14
      my $config;
      my $project_id = $CONFIG->{liquidplanner}{project}{$target->username};
      $Logger->log([
        "Looking for project for %s found %s",
        $target->username,
        $project_id // '(undef)',
      ]);

      $project_id{ $project_id }++ if $project_id;
    } elsif ($target) {
      push @no_lp, $target->username;
    } else {
      push @unknown, $name;
    }
  }

  if (@unknown or @no_lp) {
    my @fail;

    if (@unknown) {
      my $str = @unknown == 1 ? "$unknown[0] is"
              : @unknown == 2 ? "$unknown[0] or $unknown[1] are"
              : join(q{, }, @unknown[0 .. $#unknown-1], "or $unknown[-1] are");
      push @fail, "I don't know who $str.";
    }

    if (@no_lp) {
      my $str = @no_lp == 1 ? $no_lp[0]
              : @no_lp == 2 ? "$no_lp[0] or $no_lp[1]"
              : join(q{, }, @no_lp[0 .. $#no_lp-1], "or $no_lp[-1]");
      push @fail, "There's no LiquidPlanner user for $str.";
    }

    return $rch->reply(join(q{  }, @fail));
  }

  my $flags = $self->_strip_name_flags($name);
  my $urgent = $flags->{urgent};
  my $start  = $flags->{running};

  my $via = $rch->channel->describe_event($event);
  my $user = $event->from_user;
  $user = undef unless $user && $user->lp_auth_header;

  my $description = sprintf 'created by %s in response to %s',
    'pizzazz', # XXX -- alh, 2018-03-14
    $via;

  my $project_id = (keys %project_id)[0] if 1 == keys %project_id;

  my $arg = {};

  my $task = $self->_create_lp_task($rch, {
    name   => $name,
    urgent => $urgent,
    user   => $user,
    owners => \@owners,
    description => $description,
    project_id  => $project_id,
  }, $arg);

  unless ($task) {
    if ($arg->{already_notified}) {
      return;
    } else {
      return $rch->reply(
        "Sorry, something went wrong when I tried to make that task.",
        $arg,
      );
    }
  }

  my $rcpt = join q{ and }, map {; $_->username } @owners;

  my $reply = sprintf
    "Task for $rcpt created: https://app.liquidplanner.com/space/%s/projects/show/%s",
    $WKSP_ID,
    $task->{id};

  if ($start) {
    if ($user) {
      my $res = $self->http_post_for_user($user, "$LP_BASE/tasks/$task->{id}/timer/start");
      my $timer = eval { $JSON->decode( $res->decoded_content ); };
      if ($res->is_success && $timer->{running}) {
        $user->last_lp_timer_id($timer->{id});

        $reply =~ s/created:/created, timer running:/;
      } else {
        $reply =~ s/created:/created, timer couldn't be started:/;
      }
    } else {
      $reply =~ s/created:/created, timer couldn't be started:/;
    }
  }

  $rch->reply($reply);
}

sub lp_tasks_for_user ($self, $user, $count, $which='tasks') {
  my $res = $self->http_get_for_user(
    $user,
    "$LP_BASE/upcoming_tasks?limit=200&flat=true&member_id=" . $user->lp_id,
  );

  unless ($res->is_success) {
    $Logger->log("failed to get tasks from LiquidPlanner: " . $res->as_string);
    return;
  }

  my $tasks = $JSON->decode( $res->decoded_content );

  @$tasks = grep {; $_->{type} eq 'Task' } @$tasks;

  if ($which eq 'tasks') {
    @$tasks = grep {;
      (! grep { $CONFIG->{liquidplanner}{package}{inbox} == $_ } $_->{parent_ids}->@*)
      &&
      (! grep { $CONFIG->{liquidplanner}{package}{inbox} == $_ } $_->{package_ids}->@*)
    } @$tasks;
  } else {
    my $package_id = $CONFIG->{liquidplanner}{package}{ $which };
    unless ($package_id) {
      $Logger->log("can't find package_id for '$which'");
      return;
    }

    @$tasks = grep {;
      (grep { $package_id == $_ } $_->{parent_ids}->@*)
      ||
      (grep { $package_id == $_ } $_->{package_ids}->@*)
    } @$tasks;
  }

  splice @$tasks, $count;

  my $urgent = $CONFIG->{liquidplanner}{package}{urgent};
  for (@$tasks) {
    $_->{name} = "[URGENT] $_->{name}"
      if (grep { $urgent == $_ } $_->{parent_ids}->@*)
      || (grep { $urgent == $_ } $_->{package_ids}->@*);
  }

  return $tasks;
}

sub _handle_tasks ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  my ($how_many) = $text =~ /\Atasks\s+([0-9]+)\z/;

  my $per_page = 5;
  my $page = $how_many && $how_many > 0 ? $how_many : 1;

  unless ($page <= 10) {
    return $rch->reply(
      "If it's not in your first ten pages, better go to the web.",
    );
  }

  my $count = $per_page * $page;
  my $start = $per_page * ($page - 1);

  my $lp_tasks = $self->lp_tasks_for_user($user, $count, 'tasks');

  for my $task (splice @$lp_tasks, $start, $per_page) {
    $rch->private_reply("$task->{name} ($LINK_BASE$task->{id})");
  }

  $rch->reply("responses to <tasks> are sent privately") if $event->is_public;
}

sub _handle_task_like ($self, $event, $rch, $command, $count) {
  my $user = $event->from_user;
  my $lp_tasks = $self->lp_tasks_for_user($user, $count, $command);

  unless (@$lp_tasks) {
    my $suffix = $command =~ /(inbox|urgent)/n
               ? ' \o/'
               : '';
    $rch->reply("you don't have any open $command tasks right now.$suffix");
    return;
  }

  for my $task (@$lp_tasks) {
    $rch->private_reply("$task->{name} ($LINK_BASE$task->{id})");
  }

  $rch->reply("responses to <$command> are sent privately") if $event->is_public;
}


sub _handle_inbox ($self, $event, $rch, $text) {
  return $self->_handle_task_like($event, $rch, 'inbox', 200);
}

sub _handle_urgent ($self, $event, $rch, $text) {
  return $self->_handle_task_like($event, $rch, 'urgent', 100);
}

sub _handle_recurring ($self, $event, $rch, $text) {
  return $self->_handle_task_like($event, $rch, 'recurring', 100);
}

sub _handle_plus_plus ($self, $event, $rch, $text) {
  my $user = $event->from_user;

  return $rch->reply($ERR_NO_LP)
    unless $user && $user->lp_auth_header;

  unless (length $text) {
    return $rch->reply("Thanks, but I'm only as awesome as my creators.");
  }

  my $who     = $event->from_user->username;
  my $pretend = "task for $who: $text";

  if ($text =~ /\A\s*that\s*\z/) {
    my $key   = join qq{$;}, $event->from_channel->name, $event->from_address;
    my $last  = $self->get_last_utterance($key);

    unless (length $last) {
      return $rch->reply("I don't know what 'that' refers to.");
    }

    $pretend = "task for $who: $last";
  }

  return $self->_handle_task($event, $rch, $pretend);
}

my @BYE = (
  "See you later, alligator.",
  "After a while, crocodile.",
  "Time to scoot, little newt.",
  "See you soon, raccoon.",
  "Auf wiedertippen!",
  "Later.",
  "Peace.",
  "¡Adios!",
  "Au revoir.",
  "221 2.0.0 Bye",
  "+++ATH0",
  "Later, gator!",
  "Pip pip.",
  "Aloha.",
  "Farewell, %n.",
);

sub _handle_good ($self, $event, $rch, $text) {
  my $user = $event->from_user;

  my ($what) = $text =~ /^([a-z_]+)/i;
  my ($reply, $expand, $stop, $end_of_day);

  if    ($what eq 'morning')    { $reply  = "Good morning!";
                                  $expand = 'morning'; }

  elsif ($what eq 'day_au')     { $reply  = "How ya goin'?";
                                  $expand = 'morning'; }

  elsif ($what eq 'day_de')     { $reply  = "Doch, wenn du ihn siehst!";
                                  $expand = 'morning'; }

  elsif ($what eq 'day')        { $reply  = "Long days and pleasant nights!";
                                  $expand = 'morning'; }

  elsif ($what eq 'afternoon')  { $reply  = "You, too!";
                                  $expand = 'afternoon' }

  elsif ($what eq 'evening')    { $reply  = "I'll be here when you get back!";
                                  $stop   = 1; }

  elsif ($what eq 'night')      { $reply  = "Sleep tight!";
                                  $stop   = 1;
                                  $end_of_day = 1; }

  elsif ($what eq 'riddance')   { $reply  = "I'll outlive you all.";
                                  $stop   = 1;
                                  $end_of_day = 1; }

  elsif ($what eq 'bye')        { $reply  = pick_one(\@BYE);
                                  $stop   = 1;
                                  $end_of_day = 1; }

  if ($reply) {
    $reply =~ s/%n/$user->username/ge;
  }

  return $rch->reply($reply) if $reply and not $user->lp_auth_header;

  # TODO: implement expandos
  if ($expand && $user->tasks_for_expando($expand)) {
    $self->expand_tasks($rch, $event, $expand, "$reply  ");
    $reply = '';
  }

  if ($stop) {
    my $res = $self->http_get_for_user($user, "$LP_BASE/my_timers");

    if ($res->is_success) {
      my @timers = grep {; $_->{running} }
                   @{ $JSON->decode( $res->decoded_content ) };

      if (@timers) {
        return $rch->reply("You've got a running timer!  You should commit it.");
      }
    }
  }

  if ($end_of_day && (my $sy_timer = $user->timer)) {
    my $time = parse_time_hunk('until tomorrow', $user);
    $sy_timer->chilltill($time);
  }

  return $rch->reply($reply) if $reply;
}

sub _handle_expand ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  my ($what) = $text =~ /^([a-z_]+)/i;
  $self->expand_tasks($rch, $event, $what);
}

sub expand_tasks ($self, $rch, $event, $expand_target, $prefix='') {
  my $user = $event->from_user;

  unless ($expand_target && $expand_target =~ /\S/) {
    my @names = sort $user->defined_expandoes;
    return $rch->reply($prefix . "You don't have any expandoes") unless @names;
    return $rch->reply($prefix . "Your expandoes: " . (join q{, }, @names));
  }

  my @tasks = $user->tasks_for_expando($expand_target);
  return $rch->reply($prefix . "You don't have an expando for <$expand_target>")
    unless @tasks;

  my $parent = $CONFIG->{liquidplanner}{package}{recurring};
  my $desc = $rch->channel->describe_event($event);

  my (@ok, @fail);
  for my $task (@tasks) {
    my $payload = { task => {
      name        => $task,
      parent_id   => $parent,
      assignments => [ { person_id => $user->lp_id } ],
      description => $desc,
    } };

    $Logger->log([ "creating LP task: %s", $payload ]);

    my $res = $self->http_post_for_user($user,
      "$LP_BASE/tasks",
      Content_Type => 'application/json',
      Content => $JSON->encode($payload),
    );
    if ($res->is_success) {
      push @ok, $task;
    } else {
      $Logger->log([ "error creating LP task: %s", $res->decoded_content ]);
      push @fail, $task;
    }
  }
  my $reply;
  if (@ok) {
    $reply = "I created your $expand_target tasks: " . join(q{; }, @ok);
    $reply .= "  Some tasks failed to create: " . join(q{; }, @fail) if @fail;
  } elsif (@fail) {
    $reply = "Your $expand_target tasks couldn't be created.  Sorry!";
  } else {
    $reply = "Something impossible happened.  How exciting!";
  }
  $rch->reply($prefix . $reply);
}


sub resolve_name ($self, $name, $who) {
  return unless $name;

  $name = lc $name;
  $name = $who if $name eq 'me' || $name eq 'my' || $name eq 'myself' || $name eq 'i';

  my $user = $self->hub->user_directory->user_by_name($name);
  $user ||= $self->hub->user_directory->user_by_nickname($name);

  return $user;
}

sub _create_lp_task ($self, $rch, $my_arg, $arg) {
  my $config; # XXX REAL CONFIG
  my %container = (
    package_id  => $my_arg->{urgent}
                ? $CONFIG->{liquidplanner}{package}{urgent}
                : $CONFIG->{liquidplanner}{package}{inbox},
    parent_id   => $my_arg->{project_id}
                ?  $my_arg->{project_id}
                :  undef,
  );

  if ($my_arg->{name} =~ s/#(.*)$//) {
    my $project = lc $1;

    my $projects = $self->project_named($project);

    unless ($projects && @$projects) {
      $arg->{already_notified} = 1;

      return $rch->reply(
          "I am not aware of a project named '$project'. (Try 'projects' "
        . "to see what projects I know about.)",
      );
    }

    if (@$projects > 1) {
      return $rch->reply(
          "More than one LiquidPlanner project has the nickname '$project'. "
        . "Their ids are: "
        . join(q{, }, map {; $_->{id} } @$projects),
      );
    }

    $container{parent_id} = $projects->[0]{id};
  }

  $container{parent_id} = delete $container{package_id}
    unless $container{parent_id};

  my $payload = { task => {
    name        => $my_arg->{name},
    assignments => [ map {; { person_id => $_->lp_id } } @{ $my_arg->{owners} } ],
    description => $my_arg->{description},

    %container,
  } };

  my $as_user = $my_arg->{user} // $self->master_lp_user;

  my $res = $self->http_post_for_user(
    $as_user,
    "$LP_BASE/tasks",
    Content_Type => 'application/json',
    Content => $JSON->encode($payload),
  );

  unless ($res->is_success) {
    $Logger->log("error creating task: " . $res->as_string);
    return;
  }

  my $task = $JSON->decode($res->decoded_content);

  return $task;
}

sub _strip_name_flags ($self, $name) {
  my ($urgent, $running);
  if ($name =~ s/\s*\(([!>]+)\)\s*\z//) {
    my ($code) = $1;
    $urgent   = $code =~ /!/;
    $running  = $code =~ />/;
  } elsif ($name =~ s/\s*((?::timer_clock:|:hourglass(?:_flowing_sand)?:|:exclamation:)+)\s*\z//) {
    my ($code) = $1;
    $urgent   = $code =~ /exclamation/;
    $running  = $code =~ /timer_clock|hourglass/;
  }

  $_[1] = $name;

  return { urgent => $urgent, running => $running };
}

sub lp_timer_for_user ($self, $user) {
  return unless $user->lp_auth_header;

  my $res = $self->http_get_for_user($user, "$LP_BASE/my_timers");
  return -1 unless $res->is_success; # XXX WARN

  my ($timer) = grep {; $_->{running} }
                $JSON->decode( $res->decoded_content )->@*;

  if ($timer) {
    $user->last_lp_timer_id($timer->{id});
  }

  return $timer;
}

sub _handle_showtime ($self, $event, $rch, $text) {
  my $user  = $event->from_user;
  my $timer = $user && $user->has_lp_id ? $user->timer : undef;

  return $rch->reply($ERR_NO_LP)
    unless $timer;

  if ($timer->has_chilltill and $timer->chilltill > time) {
    if ($timer->is_business_hours) {
      $rch->reply("Okay, back to work!");
    } else {
      $rch->reply("Back to normal business hours, then.");
    }
  } elsif ($timer->is_business_hours) {
    $rch->reply("I thought it was already showtime!");
  } else {
    $timer->start_showtime;
    return $rch->reply("Okay, business hours extended!");
  }

  $timer->clear_chilltill;
  return;
}

sub _handle_shows ($self, $event, $rch, $text) {
  return $self->_handle_chill($event, $rch, 'until tomorrow')
    if $text =~ /\s*over\s*[+!.]*\s*/i;

  return;
}

sub _handle_chill ($self, $event, $rch, $text) {
  my $user = $event->from_user;

  return $rch->reply($ERR_NO_LP)
    unless $user && $user->lp_auth_header;

  my $res = $self->http_get_for_user($user, "$LP_BASE/my_timers");
  if ($res->is_success) {
    my @timers = grep {; $_->{running} }
                 @{ $JSON->decode( $res->decoded_content ) };

    if (@timers) {
      return $rch->reply("You've got a running timer!  Use 'commit' instead.");
    }
  } # XXX - Error handling? -- alh, 2018-03-16

  my $sy_timer = $user->timer;

  $text =~ s/[.!?]+\z// if length $text;

  if (! length $text or $text =~ /^until\s+I'm\s+back\s*$/i) {
    $sy_timer->chill_until_active(1);
    # XXX - Save state
    return $rch->reply("Okay, I'll stop pestering you until you've active again.");
  }

  my $time = parse_time_hunk($text, $user);
  return $rch->reply("Sorry, I couldn't parse '$text' into a time")
    unless $time;

  my $when = DateTime->from_epoch(
    time_zone => $user->time_zone,
    epoch     => $time,
  )->format_cldr("yyyy-MM-dd HH:mm zzz");

  if ($time <= time) {
    $rch->reply("That sounded like you want to chill until the past ($when).");
    return;
  }

  $sy_timer->chilltill($time);
  # XXX - Save state
  $rch->reply("Okay, no more nagging until $when");
}

sub _handle_commit ($self, $event, $rch, $comment) {
  my $user = $event->from_user;
  return $rch->reply($ERR_NO_LP) unless $user->lp_auth_header;

  my %meta;
  while ($comment =~ s/(?:\A|\s+)(DONE|STOP|CHILL)\z//) {
    $meta{$1}++;
  }

  $meta{DONE} = 1 if $comment =~ /\Adone\z/i;
  $meta{STOP} = 1 if $meta{DONE} or $meta{CHILL};

  my $lp_timer = $self->lp_timer_for_user($user);

  return $rch->reply("You don't seem to have a running timer.")
    unless $lp_timer && ref $lp_timer; # XXX <-- stupid return type

  my $sy_timer = $user->timer;
  return $rch->reply("You don't timer-capable.") unless $sy_timer;

  my $task_res = $self->http_get_for_user($user, "$LP_BASE/tasks/$lp_timer->{item_id}");

  unless ($task_res->is_success) {
    return $rch->reply("I couldn't log the work because I couldn't find the current task's activity id.");
  }

  my $task = $JSON->decode($task_res->decoded_content);
  my $activity_id = $task->{activity_id};

  unless ($activity_id) {
    return $rch->reply("I couldn't log the work because the task doesn't have a defined activity.");
  }

  my $restart = $meta{STOP} ? 0 : 1;

  my $content = $JSON->encode({
    is_done => $meta{DONE} ? \1 : \0,
    comment => $comment,
    restart => \$restart,
    activity_id => $activity_id,
  });

  if ($meta{STOP} and ! $sy_timer->chilling) {
    if ($meta{CHILL}) {
      $sy_timer->chill_until_active(1);
    } else {
      # Don't complain 30s after we stop work!  Give us a couple minutes to
      # move on to the next task. -- rjbs, 2015-04-21
      $sy_timer->chilltill(time + 300);
    }
  }

  my $commit_res = $self->http_post_for_user(
    $user,
    "$LP_BASE/tasks/$lp_timer->{item_id}/timer/commit",
    Content => $content,
    Content_Type => 'application/json',
  );

  unless ($commit_res->is_success) {
    $Logger->log([ "bad timer commit response: %s", $commit_res->as_string ]);
    return $rch->reply("I couldn't commit your work, sorry.");
  }

  $sy_timer->clear_last_nag;

  if ($restart) {
    my $start_res = $self->http_post_for_user(
      $user,
      "$LP_BASE/tasks/$lp_timer->{item_id}/timer/start",
    );
    $meta{RESTARTFAIL} = ! $start_res->is_success;
  }

  my $also
    = $meta{DONE}  ? " and marked the task done"
    : $meta{CHILL} ? " stopped the timer, and will chill until you're back"
    : $meta{STOP}  ? " and stopped the timer"
    :                "";

  my $time = concise( duration( $lp_timer->{running_time} * 3600 ) );
  $rch->reply("Okay, I've committed $time of work$also. Task was: $task->{name}");
}


sub _handle_abort ($self, $event, $rch, $text) {
  return $rch->reply("I didn't understand your abort request.")
    unless $text eq 'timer';

  my $user = $event->from_user;
  return $rch->reply($ERR_NO_LP) unless $user->lp_auth_header;

  my $res = $self->http_get_for_user($user, "$LP_BASE/my_timers");

  return $rch->reply("Something went wrong") unless $res->is_success;

  my ($timer) = grep {; $_->{running} }
                $JSON->decode( $res->decoded_content )->@*;

  return $rch->reply("You don't have an active timer to abort.")
    unless $timer;

  my $stop_res = $self->http_post_for_user($user, "$LP_BASE/tasks/$timer->{item_id}/timer/stop");
  my $clr_res  = $self->http_post_for_user($user, "$LP_BASE/tasks/$timer->{item_id}/timer/clear");

  if ($stop_res->is_success and $clr_res->is_success) {
    $user->timer->clear_last_nag;
    $rch->reply("Okay, I stopped and cleared your active timer.");
  } else {
    $rch->reply("Something went wrong aborting your timer.");
  }
}

sub _handle_start ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  return $rch->reply($ERR_NO_LP) unless $user->lp_auth_header;

  if ($text =~ /\A[0-9]+\z/) {
    # TODO: make sure the task isn't closed! -- rjbs, 2016-01-25
    # TODO: print the description of the task instead of its number -- rjbs,
    # 2016-01-25
    my $start_res = $self->http_post_for_user($user, "$LP_BASE/tasks/$text/timer/start");
    my $timer = eval { $JSON->decode( $start_res->decoded_content ); };

    if ($start_res->is_success && $timer->{running}) {
      $user->last_lp_timer_id($timer->{id});

      my $task_res = $self->http_get_for_user($user, "$LP_BASE/tasks/$timer->{item_id}");
      my $name = $task_res->is_success
               ? $JSON->decode($task_res->decoded_content)->{name}
               : '??';

      return $rch->reply("Started task: $name ($LINK_BASE$timer->{item_id})");
    } else {
      return $rch->reply("I couldn't start the timer for $text.");
    }
  } elsif ($text eq 'next') {
    my $lp_tasks = $self->lp_tasks_for_user($user, 1);

    unless ($lp_tasks && $lp_tasks->[0]) {
      return $rch->reply("I can't get your tasks to start the next one.");
    }

    my $task = $lp_tasks->[0];
    my $start_res = $self->http_post_for_user($user, "$LP_BASE/tasks/$task->{id}/timer/start");
    my $timer = eval { $JSON->decode( $start_res->decoded_content ); };

    if ($start_res->is_success && $timer->{running}) {
      $user->last_lp_timer_id($timer->{id});
      return $rch->reply("Started task: $task->{name} ($LINK_BASE$task->{id})");
    } else {
      return $rch->reply("I couldn't start your next task.");
    }
  }

  return -1;
}

# XXX move this into User object?
sub last_lp_timer_for_user ($self, $user) {
  return unless $user->lp_auth_header;
  return unless my $lp_timer_id = $user->last_lp_timer_id;

  my $res = $self->http_get_for_user($user, "$LP_BASE/my_timers");
  return unless $res->is_success;

  my ($timer) = grep {; $_->{id} eq $lp_timer_id }
                $JSON->decode( $res->decoded_content )->@*;

  return $timer;
}

sub _handle_resume ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  return $rch->reply($ERR_NO_LP) unless $user->lp_auth_header;

  my $lp_timer = $self->lp_timer_for_user($user);

  if ($lp_timer && ref $lp_timer) {
    my $task_res = $self->http_get_for_user($user, "$LP_BASE/tasks/$lp_timer->{item_id}");

    unless ($task_res->is_success) {
      return $rch->reply("You already have a running timer (but I couldn't figure out its task...)");
    }

    my $task = $JSON->decode($task_res->decoded_content);
    return $rch->reply("You already have a running timer ($task->{name})");
  }

  my $last_lp_timer = $self->last_lp_timer_for_user($user);

  unless ($last_lp_timer) {
    return $rch->reply("I'm not aware of any previous timer you had running. Sorry!");
  }

  my $task_res = $self->http_get_for_user($user, "$LP_BASE/tasks/$last_lp_timer->{item_id}");

  unless ($task_res->is_success) {
    return $rch->reply("I found your timer but I couldn't figure out its task...");
  }

  my $task = $JSON->decode($task_res->decoded_content);
  my $res = $self->http_post_for_user($user, "$LP_BASE/tasks/$task->{id}/timer/start");

  unless ($res->is_success) {
    return $rch->reply("I failed to resume the timer for $task->{name}, sorry!");
  }

  return $rch->reply("Timer resumed. Task is: $task->{name}");
}


sub _handle_stop ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  return $rch->reply($ERR_NO_LP) unless $user->lp_auth_header;

  return $rch->reply("Quit it!  I'm telling mom!")
    if $text =~ /\Ahitting yourself[.!]*\z/;

  return $rch->reply("I didn't understand your stop request.")
    unless $text eq 'timer';

  my $res = $self->http_get_for_user($user, "$LP_BASE/my_timers");
  return $rch->reply("Something went wrong") unless $res->is_success;

  my ($timer) = grep {; $_->{running} }
                $JSON->decode( $res->decoded_content )->@*;

  return $rch->reply("You don't have any active timers to stop.") unless $timer;

  my $stop_res = $self->http_post_for_user($user, "$LP_BASE/tasks/$timer->{item_id}/timer/stop");
  return $rch->reply("I couldn't stop your active timer.")
    unless $stop_res->is_success;

  $user->timer->clear_last_nag;
  return $rch->reply("Okay, I stopped your active timer.");
}

sub _handle_done ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  return $rch->reply($ERR_NO_LP) unless $user->lp_auth_header;

  my $next;
  my $chill;
  if ($text) {
    my @things = split /\s*,\s*/, $text;
    for (@things) {
      if ($_ eq 'next')  { $next  = 1; next }
      if ($_ eq 'chill') { $chill = 1; next }

      return -1;
    }

    return $rch->reply("No, it's nonsense to chill /and/ start a new task!")
      if $chill && $next;
  }

  $self->_handle_commit($event, $rch, 'DONE');
  $self->_handle_start($event, $rch, 'next') if $next;
  $self->_handle_chill($event, $rch, "until I'm back") if $chill;
  return;
}

sub _handle_reset ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  return $rch->reply($ERR_NO_LP) unless $user->lp_auth_header;

  return $rch->reply("I didn't understand your reset request. (try 'reset timer')")
    unless ($text // 'timer') eq 'timer';

  my $res = $self->http_get_for_user($user, "$LP_BASE/my_timers");

  return $rch->reply("Something went wrong") unless $res->is_success;

  my ($timer) = grep {; $_->{running} }
                $JSON->decode( $res->decoded_content )->@*;

  $rch->reply("You don't have an active timer to abort.") unless $timer;

  my $task_id = $timer->{item_id};
  my $clr_res  = $self->http_post_for_user($user, "$LP_BASE/tasks/$task_id/timer/clear");

  return $rch->reply("Something went wrong resetting your timer.")
    unless $clr_res->is_success;

  $user->timer->clear_last_nag;


  my $start_res = $self->http_post_for_user($user, "$LP_BASE/tasks/$task_id/timer/start");
  my $restart_timer = eval { $JSON->decode( $start_res->decoded_content ); };

  if ($start_res->is_success && $restart_timer->{running}) {
    $user->last_lp_timer_id($timer->{id});
    $rch->reply("Okay, I cleared your active timer but left it running.");
  } else {
    $rch->reply("Okay, I cleared your timer but couldn't restart it...sorry!");
  }
}

sub _handle_spent ($self, $event, $rch, $text) {
  my $user = $event->from_user;

  return $rch->reply($ERR_NO_LP)
    unless $user && $user->lp_auth_header;

  my ($dur_str, $name) = $text =~ /\A(.+?)(?:\s*:|\s*\son)\s+(\S.+)\z/;
  unless ($dur_str && $name) {
    return $rch->reply("Does not compute.  Usage:  spent DURATION on DESC-or-ID-or-URL");
  }

  my $duration;
  my $ok = eval { $duration = parse_duration($dur_str); 1 };
  unless ($ok) {
    return $rch->reply("I didn't understand how long you spent!");
  }

  if ($duration > 12 * 86_400) {
    my $dur_restr = duration($duration);
    return $rch->reply(
        qq{You said to spend "$dur_str" which I read as $dur_restr.  }
      . qq{That's too long!},
    );
  }

  my $flags = $self->_strip_name_flags($name);

  if (
    $name =~ m{^\s*(?:https://app.liquidplanner.com/space/$WKSP_ID/.*/)?([0-9]+)/?\s*\z}
  ) {
    my ($task_id, $comment) = ($1, $2);
    $comment //= "";

    my $task_res = $self->http_get_for_user($user, "$LP_BASE/tasks/$task_id");

    my $activity_id;
    unless ($task_res->is_success) {
      return $rch->reply("I couldn't log the work because I couldn't find the task.");
    }

    my $task = $JSON->decode($task_res->decoded_content);
    $activity_id = $task->{activity_id};

    unless ($activity_id) {
      return $rch->reply("I couldn't log the work because the task doesn't have a defined activity.");
    }

    my $res = $self->http_post_for_user($user,
      "$LP_BASE/tasks/$task->{id}/track_time",
      Content_Type => 'application/json',
      Content => $JSON->encode({
        activity_id => $task->{activity_id},
        member_id => $user->lp_id,
        work      => $duration / 3600,
        ($comment ? (comment => $comment ) : ()),
      }),
    );

    unless ($res->is_success) {
      $Logger->log("error tracking time: " . $res->as_string);
      return $rch->reply("I couldn't log your time, sorry.");
    }

    my $uri = sprintf
      'https://app.liquidplanner.com/space/%s/projects/show/%s',
      $WKSP_ID,
      $task->{id};

    if ($flags->{running}) {
      my $res = $self->http_post_for_user($user, "$LP_BASE/tasks/$task->{id}/timer/start");
      my $timer = eval { $JSON->decode( $res->decoded_content ); };
      if ($res->is_success && $timer->{running}) {
        $user->last_lp_timer_id($timer->{id});
        return $rch->reply("I logged that time on task ($task->{name}) and started your timer here: $uri");
      } else {
        return $rch->reply("I couldn't start the timer on task ($task->{name}), but I logged that time here: $uri");
      }
    }

    return $rch->reply("I logged that time on your task ($task->{name} here: $uri)");
  }

  my $arg = {};

  my $task = $self->_create_lp_task($rch, {
    name   => $name,
    urgent => $flags->{urgent},
    user   => $user,
    owners => [ $user ],
    description => 'Created by Synergy in response to a "spent" command.', # XXX
  }, $arg);

  unless ($task) {
    if ($arg->{already_notified}) {
      return;
    } else {
      return $rch->reply(
        "Sorry, something went wrong when I tried to make that task.",
      );
    }
  }

  my $uri = sprintf
    'https://app.liquidplanner.com/space/%s/projects/show/%s',
    $WKSP_ID,
    $task->{id};

  my $res = $self->http_post_for_user($user,
    "$LP_BASE/tasks/$task->{id}/track_time",
    Content_Type => 'application/json',
    Content => $JSON->encode({
      activity_id => $task->{activity_id},
      member_id => $user->lp_id,
      work      => $duration / 3600,
      is_done   => ($flags->{running} ? \0 : \1),
    }),
  );

  unless ($res->is_success) {
    $Logger->log("error tracking time: " . $res->as_string);
    return $rch->reply(
      "I was able to create the task, but not log your time.  Drat.  $uri",
    );
  }

  if ($flags->{running}) {
    my $res = $self->http_post_for_user($user, "$LP_BASE/tasks/$task->{id}/timer/start");
    my $timer = eval { $JSON->decode( $res->decoded_content ); };
    if ($res->is_success && $timer->{running}) {
      $user->last_lp_timer_id($timer->{id});
      return $rch->reply("I logged that time and started your timer here: $uri");
    } else {
      return $rch->reply("I couldn't start the timer, but I logged that time here: $uri");
    }
  }

  return $rch->reply("I logged that time here: $uri");
}

sub _handle_projects ($self, $event, $rch, $text) {
  my @sorted = sort $self->projects;

  $rch->reply("responses to <projects> are sent privately") if $event->is_public;
  $rch->private_reply('Known projects:');

  for my $project (@sorted) {
    my $id = $self->project_named($project)->[0]->{id};   # cool, LP
    $rch->private_reply("$project ($LINK_BASE$id)");
  }
}

1;