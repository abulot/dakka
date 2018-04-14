{-# LANGUAGE Safe #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
module Dakka.Actor.Base
    ( HPathT(..)
    , root
    , ref
    , ActorRef
    , ActorRefConstraints
    , ActorContext(..)
    , create
    , Actor(..)
    , ActorAction
    , Behavior
    , behaviorOf
    , LeafActor
    , PureActor
    , Signal(..)
    , noop
    ) where

import "base" Data.Kind ( Constraint )
import "base" Data.Typeable ( Typeable )
import "base" Data.Proxy ( Proxy(..) )
import "base" Control.Applicative ( Const(..) )

import "mtl" Control.Monad.State.Class ( MonadState )

import Dakka.Constraints
    ( (:∈)
    , ImplementsAll, ImplementedByAll
    , RichData, RichData1
    )
import Dakka.Path
    ( Path(..), Tip, PRoot, root
    , ref, HPathT(..), AllSegmentsImplement
    )

import Dakka.Actor.ActorId ( ActorId )

-- ---------- --
--  ActorRef  --
-- ---------- --

type ActorRef p = HPathT p ActorId 

type ActorRefConstraints p
  = ( ConsistentActorPath p
    , Actor (Tip p)
    , Actor (PRoot p)
    , p `AllSegmentsImplement` Actor
    , p `AllSegmentsImplement` Typeable
    )

type family ConsistentActorPath (p :: Path *) :: Constraint where
    ConsistentActorPath ('Root a)  = (Actor a)
    ConsistentActorPath (as ':/ a) = (a :∈ Creates (Tip as), ConsistentActorPath as)

-- -------------- --
--  ActorContext  --
-- -------------- --

-- | Execution Context of an 'Actor'.
-- Has to provide ways to:
--
--     * change the state of an `Actor` (through `MonadState`)
--
--     * send messages to other actors
--
--     * create new actors.
-- 
class ( ActorRefConstraints p 
      , MonadState (Tip p) m
      ) => ActorContext 
          (p :: Path *)
          (m :: * -> *)
      | m -> p
    where
      {-# MINIMAL self, create', (send | (!)) #-}

      -- | reference to the currently running 'Actor'
      self :: ConsistentActorPath p => m (ActorRef p)

      -- | Creates a new `Actor` of type 'b' with provided start state
      create' :: ( Actor b
                 , b :∈ Creates (Tip p)
                 , ActorRefConstraints (p ':/ b)
                 ) => Proxy b -> m (ActorRef (p ':/ b))

      -- | Send a message to another actor
      send :: ( PRoot p ~ PRoot b
              , Actor (Tip b)
              , ActorRefConstraints b
              ) => ActorRef b -> Message (Tip b) (PRoot p) -> m ()
      send = (!)

      -- | Alias for 'send' to enable akka style inline send.
      (!) :: ( PRoot p ~ PRoot b
             , Actor (Tip b)
             , ActorRefConstraints b
             ) => ActorRef b -> Message (Tip b) (PRoot b) -> m () 
      (!) = send

create :: ( Actor b
          , ActorContext p m 
          , b :∈ Creates (Tip p)
          , ConsistentActorPath (p ':/ b)
          ) => m (ActorRef (p ':/ b))
create = create' Proxy

-- ------- --
--  Actor  --
-- ------- --

-- | A Behavior of an 'Actor' defines how an Actor reacts to a message given a specific state.
-- A Behavior may be executed in any 'ActorContext' that has all of the actors 'Capabillities'.
type ActorAction a r
  = forall p m.
    ( Actor a
    , Tip p ~ a
    , PRoot p ~ r
    , ActorContext p m
    , m `ImplementsAll` Capabillities a
    ) => m ()

type Behavior a = forall r. Either (Signal a) (Message a r) -> ActorAction a r

data Signal (a :: *) where
    Created :: Actor a => Signal a
    Obit    :: ( Actor a
               , Tip p ~ a
               , ConsistentActorPath p
               , ConsistentActorPath (p ':/ c)
               ) => ActorRef (p ':/ c) -> Signal a

class ( RichData a
      , RichData1 (Message a)
      , Actor `ImplementedByAll` Creates a
      ) => Actor
             (a :: *)
    where
      {-# MINIMAL behavior | (onMessage, onSignal) #-}

      -- | List of all types of actors that this actor may create in its lifetime.
      type Creates a :: [*]
      type Creates a = '[]
  
      -- | Type of Message this Actor may recieve
      type Message a :: * -> *
      type Message a = Const ()

      -- | List of all additional Capabillities the ActorContext has to provide For this Actors Behavior.
      type Capabillities a :: [(* -> *) -> Constraint]
      type Capabillities a = '[]

      -- | What this Actor does when recieving a message
      onMessage :: Message a r -> ActorAction a r
      onMessage = behavior . Right

      -- | What this Actor does when recieving a Signal
      onSignal :: Signal a -> ActorAction a r
      onSignal = behavior . Left

      -- | The behavior of this Actor
      behavior :: Either (Signal a) (Message a r) -> ActorAction a r
      behavior = either onSignal onMessage

      startState :: a
      default startState :: Monoid a => a
      startState = mempty

-- | A pure 'Actor' is one that has no additional Capabillities besides what a 
-- 'ActorContext' provides.
type PureActor a = (Actor a, Capabillities a ~ '[])

-- | A leaf 'Actor' is one that doesn't create any children.
type LeafActor a = (Actor a, Creates a ~ '[])

behaviorOf :: proxy a -> Behavior a
behaviorOf = const behavior

noop :: (Applicative f, Applicative g) => f (g ())
noop = pure noop'

noop' :: Applicative f => f ()
noop' = pure ()
